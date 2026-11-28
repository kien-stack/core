#!/usr/bin/env bash
# kinops Community installer (free, Apache-2.0). Run it from a clone of YOUR fork (or curl .../scripts/install.sh | bash).
# First run (cluster.yaml still on example.com) asks a few questions, writes cluster.yaml + argocd/, commits and pushes.
#   ./install.sh             configure if needed, then install (default)
#   ./install.sh configure   ask the questions again, commit, push, install
#   ./install.sh doctor      check the cluster and the repo
#   ./install.sh uninstall   remove everything the platform created, volumes included (asks first; keeps CRDs)
#   ./install.sh password argocd|infisical|grafana   print a login (once its app is deployed)
# KSTACK_VERBOSE=1 shows every step in detail.
# Everything it uses is in Git, nothing is generated:
#   cluster.yaml             your settings (domain, TLS...), passed to every chart
#   argocd/app-of-apps.yaml  the repo/branch ArgoCD follows (same URL in argocd/applications/*/appset.yaml)
#   argocd/applications/platform/appset.yaml   components + namespace: comment out an entry to disable it
# After that, ArgoCD applies whatever you push.
# Non-interactive: KSTACK_DOMAIN, KSTACK_EMAIL, KSTACK_IP, KSTACK_EXPOSURE, KSTACK_PROXY, KSTACK_ALLOWED_IPS, KSTACK_CILIUM, KSTACK_YES=1 (KSTACK_REPO/KSTACK_BRANCH: default = this clone).
# Optional environment variables (secrets, never stored in Git):
#   GIT_USERNAME / GIT_TOKEN          private GitOps repo (HTTPS)
#   DNS01_API_TOKEN                   if global.tls.issuer=letsencrypt-dns01
#   EXTERNAL_DNS_API_TOKEN            if the external-dns component is enabled
#
# What `./install.sh` (install) does, in order:
#   1. setup              first run only: questions, write cluster.yaml + argocd/, commit and push
#   2. doctor             checks: tools, cluster, Git repo, domain, TLS
#   3. bootstrap_secrets  the secrets ArgoCD cannot create (DNS01 / external-dns API tokens)
#   4. internal_dns       sslip.io / nip.io: CoreDNS resolves *.<domain> to Traefik inside the cluster
#   5. cilium             only if the cilium component is enabled (CNI, before everything else)
#   6. argocd             Helm install of ArgoCD; ArgoCD then manages itself from Git
#   7. app-of-apps        Git credential (if GIT_TOKEN), then the root Application: ArgoCD deploys every component
#   8. wait_apps          each app's status until all are Synced/Healthy
#   9. summary            URLs and logins (saved to kstack-access.txt, no passwords)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$ROOT/cluster.yaml"
APP="$ROOT/argocd/app-of-apps.yaml"
APPSET="$ROOT/argocd/applications/platform/appset.yaml"
PACK=community
CMD=install
ARGOCD_TIMEOUT=${ARGOCD_TIMEOUT:-0}   # seconds to wait for the apps, 0 = until ready
MIN_MEMORY_GI=3                       # doctor warns below this allocatable memory (all nodes)

# Colors: only on a terminal, honour NO_COLOR and TERM=dumb (bash 3.2 safe).
# COLOR_* are for stdout; COLOR_FATAL / COLOR_PROMPT / COLOR_STDERR_RESET for stderr (errors, questions).
use_color() { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
if use_color 1; then
  COLOR_TITLE=$'\033[1;36m' COLOR_OK=$'\033[32m' COLOR_WARN=$'\033[33m' COLOR_ERROR=$'\033[31m'
  COLOR_DIM=$'\033[2m' COLOR_BOLD=$'\033[1m' COLOR_RESET=$'\033[0m'
else
  COLOR_TITLE='' COLOR_OK='' COLOR_WARN='' COLOR_ERROR='' COLOR_DIM='' COLOR_BOLD='' COLOR_RESET=''
fi
if use_color 2; then
  COLOR_FATAL=$'\033[1;31m' COLOR_PROMPT=$'\033[1;36m' COLOR_STDERR_RESET=$'\033[0m'
else
  COLOR_FATAL='' COLOR_PROMPT='' COLOR_STDERR_RESET=''
fi
# TTY=1: stdout is a terminal, the install redraws lines in place
TTY=""
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
  TTY=1
fi

# QUIET=1 (install): details only with KSTACK_VERBOSE=1; warnings and errors are always shown.
# BUSY_LINE=1: a "busy" line is on screen without its newline; the next message replaces it.
QUIET="" BUSY_LINE=""
verbose() { [ -z "$QUIET" ] || [ -n "${KSTACK_VERBOSE:-}" ]; }
clear_busy_line() {
  if [ -n "$BUSY_LINE" ]; then
    printf '\r\033[K'
    BUSY_LINE=""
  fi
}
log() {
  verbose || return 0
  clear_busy_line
  printf '%s[kinops]%s %s\n' "$COLOR_TITLE" "$COLOR_RESET" "$*"
}
ok() {
  verbose || return 0
  clear_busy_line
  printf '  %sOK%s   %s\n' "$COLOR_OK" "$COLOR_RESET" "$*"
}
WARNS=()
# warn: shown at once outside install; during install collected and shown in a "Warnings" section
warn() {
  if [ -n "$QUIET" ]; then
    WARNS+=("$*")
    return 0
  fi
  clear_busy_line
  printf '  %sWARN%s %s\n' "$COLOR_WARN" "$COLOR_RESET" "$*"
}
flush_warns() {
  [ ${#WARNS[@]} -gt 0 ] || return 0
  local w
  rule Warnings
  for w in "${WARNS[@]}"; do
    printf ' %s⚠%s %s\n' "$COLOR_WARN" "$COLOR_RESET" "$w"
  done
  WARNS=()
}
ko() {
  clear_busy_line
  printf '  %sKO%s   %s\n' "$COLOR_ERROR" "$COLOR_RESET" "$*"
}
die() {
  clear_busy_line
  printf '%s[kinops] ERROR:%s %s\n' "$COLOR_FATAL" "$COLOR_STDERR_RESET" "$*" >&2
  exit 1
}
# busy NAME TEXT: shown while a step runs (terminal only); step NAME TEXT: the step's final line
busy() {
  [ -n "$TTY" ] || return 0
  clear_busy_line
  printf ' %s◌%s %-12s %s' "$COLOR_DIM" "$COLOR_RESET" "$1" "$2"
  BUSY_LINE=1
}
step() {
  clear_busy_line
  printf ' %s✓%s %-12s %s\n' "$COLOR_OK" "$COLOR_RESET" "$1" "$2"
}
# rule TITLE: a section title, "─── TITLE ─────" (50 columns)
rule() {
  local dashes
  printf -v dashes '%*s' $(( 50 - ${#1} )) ''
  printf '\n %s─── %s %s%s\n' "$COLOR_DIM" "$1" "${dashes// /─}" "$COLOR_RESET"
}
version() {
  local v
  v=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null) \
    || v=$(sed -n 's/^## \[\{0,1\}\([0-9][0-9.]*\).*/v\1/p' "$ROOT/CHANGELOG.md" 2>/dev/null | head -1) || true
  printf '%s' "$v"
}
header() {
  local v
  v=$(version)
  printf '\n %skinops%s · %s%s\n\n' "$COLOR_BOLD" "$COLOR_RESET" "$PACK" "${v:+ ${v}}"
}
# How to run this installer from the user's shell (try.sh / scripts/install.sh set KSTACK_PWD)
self_cmd() {
  local dir=$ROOT
  if [ "${KSTACK_PWD:-$PWD}" = "$ROOT" ]; then
    printf '%s' ./install.sh
    return 0
  fi
  # shellcheck disable=SC2088 # a literal ~ on purpose: only displayed, never expanded
  case "$dir" in
    "$HOME"/*) dir="~${dir#"$HOME"}" ;;
  esac
  printf '%s' "cd $dir && ./install.sh"
}

# Our public repo (and its former names): a real install needs your own fork.
# Same list in scripts/install.sh (it runs through curl | bash, it cannot share code with this file).
is_public_repo() {
  case "$1" in
    *kinopshq/core*|*kien-stack/core*|*kien-stack/essential*|*dedsxc/kien-stack-essential*) return 0 ;;
    *) return 1 ;;
  esac
}

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    doctor|install|configure|uninstall)
      CMD=$1
      ;;
    password)
      CMD=password
      PW_APP=${2:-}
      [ $# -lt 2 ] || shift
      ;;
    --pack)
      case "${2:-}" in
        "$PACK"|essential) ;;
        *) die "this repo installs the $PACK pack" ;;
      esac
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
  shift
done

cfg()  { yq -r "$1 // \"\"" "$CONFIG"; }
repo() { yq -r '.spec.source.repoURL' "$APP"; }
rev()  { yq -r '.spec.source.targetRevision' "$APP"; }

# macOS has no `timeout` nor `base64 -w0` (GNU): portable equivalents
run_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}
b64() { base64 | tr -d '\n'; }

# Public IP of this machine (what the Internet sees), empty if unknown. Default of global.platformAccess.allowedIPs.
public_ip() {
  local ip
  ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null) || true
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"
  fi
}

# global.platformAccess.allowedIPs of cluster.yaml, comma-separated
allowed_ips() { yq -r '.global.platformAccess.allowedIPs // [] | join(",")' "$CONFIG"; }

# Cloudflare edge ranges, comma-separated (offline: the list of 2026-11)
cloudflare_ips() {
  local ips
  ips=$(curl -fsS --max-time 5 -w '\n' https://www.cloudflare.com/ips-v4 https://www.cloudflare.com/ips-v6 2>/dev/null) || true
  if ! grep -qE '^[0-9.]+/[0-9]+$' <<<"$ips"; then
    ips="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18
      190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
      104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32
      2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
  fi
  tr -s ' \n' '\n' <<<"$ips" | grep -E '^[0-9a-f.:]+/[0-9]+$' | paste -sd, -
}

# Pod network of the cluster as /16s (k3s: 10.42.0.0/16): where an in-cluster cloudflared comes from
pod_cidr() {
  local cidrs
  cidrs=$(kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' 2>/dev/null \
    | tr ' ' '\n' | awk -F. 'NF == 4 {print $1 "." $2 ".0.0/16"}' | sort -u | paste -sd, -)
  printf '%s' "${cidrs:-10.42.0.0/16}"
}

# LAN of this machine (default route, e.g. 192.168.1.0/24), else the /24 of $1
lan_cidr() {
  local dev lan=""
  if command -v ip >/dev/null; then
    dev=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$dev" ]; then
      lan=$(ip -4 route show dev "$dev" scope link proto kernel 2>/dev/null | awk '$1 ~ /\// {print $1; exit}')
    fi
  fi
  printf '%s' "${lan:-${1%.*}.0/24}"
}

# Components ArgoCD will deploy: the entries of the platform ApplicationSet list, + helm/apps/*.
enabled_components() {
  local d
  yq -r '.spec.generators[0].list.elements[].app' "$APPSET"
  for d in "$ROOT"/helm/apps/*/; do
    if [ -d "$d" ]; then
      basename "$d"
    fi
  done
  return 0
}
# component_enabled NAME "<components>": is NAME in the list (one per line, from enabled_components)?
component_enabled() { grep -qx "$1" <<<"$2"; }
# k3s (and some distros) already run a metrics-server in kube-system with an immutable selector.
foreign_metrics_server() {
  local selector
  selector=$(kubectl -n kube-system get deploy metrics-server \
    -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null) || true
  [ -n "$selector" ]
}
# Sum of the allocatable memory of all nodes, in Gi (rounded down).
# kubectl prints one value per node: "16318504Ki", "15Gi", "2048Mi" or plain bytes.
allocatable_memory_gi() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' \
    | awk '
        /Ki$/ { total += $1 / 1048576; next }
        /Mi$/ { total += $1 / 1024; next }
        /Gi$/ { total += $1; next }
              { total += $1 / 1073741824 }
        END   { print int(total) }'
}

git_ls_remote() {
  local url=$1 ref=${2:-HEAD}
  if [ -n "${GIT_TOKEN:-}" ]; then
    GIT_TERMINAL_PROMPT=0 run_timeout 30 git -c credential.helper= \
      -c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | b64)" \
      ls-remote "$url" "$ref"
  else
    GIT_TERMINAL_PROMPT=0 run_timeout 30 git -c credential.helper= ls-remote "$url" "$ref"
  fi
}

# Gateway API CRDs already installed by the distribution (k3s, RKE2, AKS, GKE...): kinops can leave them alone.
gateway_crds_check() {
  local crd version owner
  [ "$(yq -r '."gateway-api-crd".enabled' "$CONFIG")" != false ] || return 0
  if ! crd=$(kubectl get crd gateways.gateway.networking.k8s.io -o json 2>/dev/null); then
    ok "Gateway API CRDs: installed by kinops"
    return 0
  fi
  # Already ours (installed by the traefik component through ArgoCD): nothing to say
  case "$(yq -r '.metadata.annotations."argocd.argoproj.io/tracking-id" // ""' <<<"$crd")" in
    traefik:*) return 0 ;;
  esac
  version=$(yq -r '.metadata.annotations."gateway.networking.k8s.io/bundle-version" // "?"' <<<"$crd")
  owner=$(yq -r '.metadata.annotations."meta.helm.sh/release-name"
    // .metadata.labels."app.kubernetes.io/managed-by" // ""' <<<"$crd")
  warn "Gateway API CRDs $version already on this cluster${owner:+ ($owner)}. To keep them and skip ours, add to cluster.yaml:
     gateway-api-crd: {enabled: false}"
}

# ---------------------------------------------------------------- doctor
doctor() {
  local fail=0 tool comps
  comps=$(enabled_components)
  log "Checking prerequisites"
  for tool in kubectl helm git yq; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool found"
    else
      ko "$tool not found in PATH"
      fail=1
    fi
  done
  if [ "$fail" -ne 0 ]; then
    ko "missing tools"
    return 1
  fi

  # Cluster
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || true)
  if kubectl version --request-timeout=10s >/dev/null 2>&1; then
    ok "cluster reachable (context: ${ctx:-?}, $(kubectl version -o json 2>/dev/null | yq -r '.serverVersion.gitVersion'))"
  else
    ko "cluster unreachable (context: ${ctx:-none})"
    fail=1
  fi
  if [ "$fail" -eq 0 ]; then
    if kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
      ok "cluster-admin rights"
    else
      ko "cluster-admin rights required"
      fail=1
    fi
    local mem
    mem=$(allocatable_memory_gi)
    if [ "$mem" -ge "$MIN_MEMORY_GI" ]; then
      ok "allocatable memory: ${mem} Gi"
    else
      warn "allocatable memory ${mem} Gi: >= 6 GB recommended"
    fi
    if component_enabled metrics-server "$comps" && foreign_metrics_server; then
      ko "this cluster already runs a metrics-server: remove the metrics-server entry in $APPSET"
      fail=1
    fi
    if component_enabled cilium "$comps" && ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
      # Another CNI already running? Look for its pods by name.
      local cni
      cni=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -Eo '^(kindnet|flannel|kube-flannel|calico|canal|weave|kube-router|aws-node|antrea)' | head -1 || true)
      if [ -n "$cni" ]; then
        ko "cilium is enabled but this cluster already has a CNI ($cni): remove the cilium entry in $APPSET again"
        fail=1
      else
        ok "no CNI found: Cilium will be installed"
      fi
    fi
    gateway_crds_check
  fi

  # Git repo followed by ArgoCD
  local r
  r=$(repo)
  if [ -z "${KSTACK_DEMO:-}" ] && is_public_repo "$r"; then
    warn "argocd/app-of-apps.yaml still points to our public repo: put your fork's URL there (and in argocd/applications/*/appset.yaml)"
  fi
  if grep -rq "repoURL: $r" "$ROOT"/argocd/applications/*/appset.yaml \
     && [ "$(grep -rh 'repoURL:' "$ROOT"/argocd/applications/*/appset.yaml | sort -u | wc -l)" -eq 1 ]; then
    ok "ApplicationSets follow the same repo as app-of-apps"
  else
    ko "argocd/applications/*/appset.yaml must use the same repoURL as argocd/app-of-apps.yaml ($r)"
    fail=1
  fi
  if git_ls_remote "$r" >/dev/null 2>&1; then
    ok "Git repo reachable: $r ($(rev))"
  else
    ko "Git repo unreachable: $r (private repo? set GIT_USERNAME/GIT_TOKEN)"
    fail=1
  fi

  # ArgoCD deploys what is in Git, not this folder: local edits must be committed and pushed
  # try.sh (demo) edits cluster.yaml / argocd/ locally on purpose and pins our public release: skip the Git checks
  if [ -n "${KSTACK_DEMO:-}" ]; then
    ok "demo mode: local settings, ArgoCD follows the public release"
  elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C "$ROOT" status --porcelain -- cluster.yaml argocd helm 2>/dev/null)" ]; then
      ko "uncommitted changes in cluster.yaml / argocd/ / helm/: ArgoCD only sees Git. Commit and push them: git -C $ROOT commit -am 'my settings' && git -C $ROOT push"
      fail=1
    else
      local remote_sha head_sha
      remote_sha=$(git_ls_remote "$r" "refs/heads/$(rev)" 2>/dev/null \
        | awk -v b="refs/heads/$(rev)" '$2==b{print $1}')
      head_sha=$(git -C "$ROOT" rev-parse HEAD)
      if [ -n "$remote_sha" ] && [ "$remote_sha" != "$head_sha" ]; then
        if git -C "$ROOT" merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
          ko "local commits not pushed to $r ($(rev)): ArgoCD only sees Git. Run: git -C $ROOT push"
          fail=1
        else
          warn "$r ($(rev)) differs from this folder: ArgoCD will deploy what is in Git"
        fi
      fi
    fi
  fi

  # Domain and TLS
  local domain
  domain=$(cfg .global.domain)
  if [ -z "$domain" ] || [ "$domain" = example.com ]; then
    ko "set global.domain in cluster.yaml (no domain? <node-ip>.sslip.io)"
    fail=1
  elif getent hosts "argocd.$domain" >/dev/null 2>&1; then
    ok "DNS: argocd.$domain -> $(getent hosts "argocd.$domain" | awk '{print $1; exit}')"
  else
    case "$domain" in
      *.sslip.io|*.nip.io) ;;   # hosts_hint gives the /etc/hosts line at the end
      *) warn "argocd.$domain does not resolve (fine if external-dns will create it; otherwise create *.$domain)" ;;
    esac
  fi

  case "$(cfg .global.tls.issuer)" in
    letsencrypt-dns01)
      if [ -n "${DNS01_API_TOKEN:-}" ] \
         || kubectl -n cert-manager get secret "$(cfg .global.tls.dns01.secretName)" >/dev/null 2>&1; then
        ok "DNS01 token"
      else
        ko "DNS01_API_TOKEN required"
        fail=1
      fi
      ;;
    letsencrypt-http01)
      warn "HTTP01: *.$domain must point to the Traefik load balancer, port 80 open from the Internet"
      ;;
    selfsigned)
      ok "self-signed certificates"
      ;;
    *)
      ko "invalid global.tls.issuer"
      fail=1
      ;;
  esac

  # Who can open the platform UIs (ArgoCD, Grafana, Infisical)
  local allowed
  allowed=$(allowed_ips)
  if [ -z "$allowed" ]; then
    warn "global.platformAccess.allowedIPs is empty: the platform UIs answer 403 to everyone. Add your IP in cluster.yaml, then git push"
  elif [[ ",$allowed," == *",0.0.0.0/0,"* ]]; then
    warn "platform UIs open to the whole Internet (global.platformAccess.allowedIPs: 0.0.0.0/0)"
  else
    ok "platform UIs allowed from: $allowed"
  fi
  if [ "$fail" -eq 0 ]; then
    log "doctor: OK"
  else
    log "doctor: some prerequisites are missing"
  fi
  return "$fail"
}

# ---------------------------------------------------------------- install
# Install helm/platform/<name> once with Helm, exactly like ArgoCD will (values.yaml + cluster.yaml);
# same release name, so ArgoCD takes it over.
helm_bootstrap() {
  local name=$1 ns=$2 out attempt
  shift 2
  # GitHub-hosted chart downloads sometimes fail (5xx): retry before giving up
  for attempt in 1 2 3 4 5; do
    out=$(helm dependency update "$ROOT/helm/platform/$name" 2>&1) && break
    if [ "$attempt" -eq 5 ]; then
      printf '%s\n' "$out" | tail -20 >&2
      die "downloading the $name chart failed"
    fi
    warn "downloading the $name chart failed, retrying ($attempt/4)"
    sleep $((attempt * 10))
  done
  if ! out=$(helm upgrade --install "$name" "$ROOT/helm/platform/$name" -n "$ns" --create-namespace \
    -f "$CONFIG" "$@" --wait --timeout 10m 2>&1); then
    clear_busy_line
    printf '%s\n' "$out" | tail -20 >&2
    die "helm install of $name failed (details above)"
  fi
  if [ -n "${KSTACK_VERBOSE:-}" ]; then
    clear_busy_line
    printf '%s\n' "$out"
  fi
}


ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# ensure_secret ns name [type] key=value...  (never overwrites an existing secret)
ensure_secret() {
  local ns=$1 name=$2
  shift 2
  local type=generic
  case "${1:-}" in
    --type=*) type=${1#--type=}; shift ;;
  esac
  ensure_ns "$ns"
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    ok "secret $ns/$name already exists"
    return
  fi
  local args=() kv
  for kv in "$@"; do
    args+=("--from-literal=$kv")
  done
  kubectl -n "$ns" create secret generic "$name" --type="$type" "${args[@]}" >/dev/null
  ok "secret $ns/$name created"
}

# Secrets ArgoCD cannot create: API tokens given in the environment (never stored in Git).
# Your app secrets: Infisical, project 'kubernetes', one folder per app,
# read through the ClusterSecretStores infisical-dev / infisical-staging / infisical-prod.
bootstrap_secrets() {
  local comps=$1 issuer
  issuer=$(cfg .global.tls.issuer)
  log "Bootstrap secrets"
  if [ "$issuer" = letsencrypt-dns01 ] && [ -n "${DNS01_API_TOKEN:-}" ]; then
    ensure_secret cert-manager "$(cfg .global.tls.dns01.secretName)" "$(cfg .global.tls.dns01.secretKey)=$DNS01_API_TOKEN"
  fi
  if component_enabled external-dns "$comps" && [ -n "${EXTERNAL_DNS_API_TOKEN:-}" ]; then
    ensure_secret external-dns external-dns-api-token "api-token=$EXTERNAL_DNS_API_TOKEN"
  fi
  return 0
}

# In-cluster resolution of *.<domain> -> Traefik. Apps call each other over https://<app>.<domain>
# (OIDC with Authentik...). On minikube, k3d or behind NAT the public IP is often not reachable from the pods:
# CoreDNS then answers with the Traefik service. On by default for sslip.io / nip.io domains,
# KSTACK_INTERNAL_DNS=1|0 to force. Idempotent. CoreDNS belongs to the distribution: bootstrap step, not ArgoCD.
internal_dns() {
  local d want corefile domain_regex rule
  d=$(cfg .global.domain)
  want=${KSTACK_INTERNAL_DNS:-}
  if [ -z "$want" ]; then
    case "$d" in
      *.sslip.io|*.nip.io) want=1 ;;
      *) want=0 ;;
    esac
  fi
  [ "$want" = 1 ] || return 0
  if ! corefile=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null) \
     || [ -z "$corefile" ]; then
    warn "no kube-system/coredns ConfigMap: resolve *.$d to traefik.traefik.svc yourself"
    return 0
  fi
  if grep -q "platform internal-dns" <<<"$corefile"; then
    ok "CoreDNS: *.$d -> Traefik (already set)"
    return 0
  fi
  # Add a rewrite rule just before the `kubernetes` plugin block of the Corefile
  domain_regex=${d//./\\.}
  rule="    rewrite name regex (.*)\\.$domain_regex traefik.traefik.svc.cluster.local answer auto # platform internal-dns"
  corefile=$(awk -v r="$rule" '!done && /^[[:space:]]*kubernetes[[:space:]]/ {print r; done=1} {print}' <<<"$corefile")
  if ! grep -q "platform internal-dns" <<<"$corefile"; then
    warn "CoreDNS: no kubernetes block, rewrite not added"
    return 0
  fi
  kubectl -n kube-system create configmap coredns --from-literal=Corefile="$corefile" --dry-run=client -o yaml \
    | kubectl -n kube-system apply -f - >/dev/null 2>&1
  kubectl -n kube-system rollout restart deployment coredns >/dev/null 2>&1 || true
  ok "CoreDNS: *.$d -> Traefik inside the cluster (KSTACK_INTERNAL_DNS=0 to skip)"
}

install() {
  local comps app_count
  comps=$(enabled_components)
  app_count=$(( $(printf '%s\n' "$comps" | grep -c .) + 1 ))   # + app-of-apps
  log "Pack $PACK -> ArgoCD will deploy: $(tr '\n' ' ' <<<"$comps")"
  busy Checks "cluster, Git repo..."
  doctor || die "checks failed: fix the problems above (details: ./install.sh doctor)"
  bootstrap_secrets "$comps"
  internal_dns
  step Checks "cluster OK, Git repo reachable"

  if component_enabled cilium "$comps"; then
    busy Cilium "installing (CNI, before everything else)..."
    # LB pool / L2 policy CRDs only exist once the Cilium operator runs: ArgoCD adds them right after.
    helm_bootstrap cilium kube-system --set ciliumLB.enabled=false
    kubectl wait --for=condition=Ready nodes --all --timeout=5m >/dev/null \
      || die "nodes not Ready after Cilium: kubectl get nodes"
    step Cilium "installed, nodes Ready"
  fi

  busy ArgoCD "installing (Helm, then self-managed)..."
  # The HTTPRoute needs the Gateway API CRDs, installed later by the traefik component:
  # ArgoCD creates it when it takes itself over
  helm_bootstrap argocd argocd --set argo-cd.server.httproute.enabled=false
  step ArgoCD installed
  log "  UI now (no ingress needed): kubectl -n argocd port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"

  if [ -n "${GIT_TOKEN:-}" ]; then
    kubectl -n argocd apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo
  namespace: argocd
  labels: {argocd.argoproj.io/secret-type: repository}
stringData:
  type: git
  url: $(repo)
  username: ${GIT_USERNAME:-git}
  password: ${GIT_TOKEN}
YAML
    ok "GitOps repo credential registered in ArgoCD"
  fi

  kubectl apply -f "$APP" >/dev/null
  local r
  r=$(repo)
  r=${r#*://}
  r=${r%.git}
  step GitOps "syncing from ${r} ($(rev))"
  access_hint

  flush_warns
  rule Deploy
  printf ' %s apps%s\n' "$app_count" "${COLOR_DIM} (Ctrl+C is safe: ArgoCD keeps going)${COLOR_RESET}"
  trap 'clear_busy_line; printf "\n\n Stopped waiting: ArgoCD keeps deploying (kubectl -n argocd get applications)\n"; summary; exit 0' INT
  local rc=0
  wait_apps "$comps" || rc=1
  trap - INT
  summary
  return $rc
}

wait_apps() {
  # ArgoCD deploys every app in parallel; this shows each app's status until all are ready (no time limit by
  # default, ARGOCD_TIMEOUT=<seconds> to cap it). Ctrl+C is safe: ArgoCD keeps deploying.
  # Terminal: one line per app, redrawn in place when a status changes. CI/pipe: one line per change.
  local comps=$1 timeout=${ARGOCD_TIMEOUT%s} app_names app app_count=0 name_width=8 start=$SECONDS
  app_names="app-of-apps $comps"
  for app in $app_names; do
    app_count=$((app_count + 1))
    if [ "${#app}" -gt "$name_width" ]; then
      name_width=${#app}
    fi
  done
  local rc=0 prev_screen="" drawn_lines=0 elapsed=0 index argocd_status status screen line icon not_ready
  local -a last_status=()
  while :; do
    # One line per Application, "<name>=<sync>/<health>" (e.g. "traefik=Synced/Healthy").
    # A leading newline lets us find "\n<name>=" for each app below, without a grep per app.
    argocd_status=$'\n'$(kubectl -n argocd get applications \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' \
      2>/dev/null || true)
    elapsed=$(( SECONDS - start ))
    screen=""
    not_ready=0
    index=0
    for app in $app_names; do
      index=$((index + 1))
      status=""
      if [[ "$argocd_status" == *$'\n'"$app="* ]]; then
        status=${argocd_status#*$'\n'"$app="}   # drop everything up to "<app>="
        status=${status%%$'\n'*}                # keep the rest of that line: "<sync>/<health>"
      fi
      case "$status" in
        Synced/Healthy) icon="${COLOR_OK}✓${COLOR_RESET}" status=ready ;;
        */Degraded)     icon="${COLOR_WARN}⚠${COLOR_RESET}" status=degraded; not_ready=$((not_ready + 1)) ;;
        ""|/|*/)        icon="${COLOR_DIM}◌${COLOR_RESET}" status=pending; not_ready=$((not_ready + 1)) ;;
        */Healthy)      icon="${COLOR_DIM}◌${COLOR_RESET}" status=syncing; not_ready=$((not_ready + 1)) ;;
        *)              icon="${COLOR_DIM}◌${COLOR_RESET}" status=$(tr '[:upper:]' '[:lower:]' <<<"${status#*/}")
                        not_ready=$((not_ready + 1)) ;;
      esac
      if [ -n "$TTY" ]; then
        printf -v line '   %s %-*s %s\033[K\n' "$icon" "$name_width" "$app" "$status"
        screen+=$line
      elif [ "${last_status[index]:-}" != "$status" ]; then
        printf '   %s %-*s %s\n' "$icon" "$name_width" "$app" "$status"
        last_status[index]=$status
      fi
    done
    # Terminal: move the cursor back up and redraw all the lines, only when something changed
    if [ -n "$TTY" ] && [ "$screen" != "$prev_screen" ]; then
      if [ "$drawn_lines" -gt 0 ]; then
        printf '\033[%dA' "$drawn_lines"
      fi
      printf '%s' "$screen"
      prev_screen=$screen
      drawn_lines=$app_count
    fi
    if [ "$not_ready" -eq 0 ]; then
      break
    fi
    if [ "${timeout:-0}" -gt 0 ] && [ "$elapsed" -ge "$timeout" ]; then
      rc=1
      break
    fi
    sleep 2
  done
  if [ "$rc" -eq 0 ]; then
    printf ' %s✓%s All apps ready (%s min %s s)\n' "$COLOR_OK" "$COLOR_RESET" $(( elapsed / 60 )) $(( elapsed % 60 ))
    return 0
  fi
  warn "still not ready after ${timeout}s (ArgoCD keeps deploying: kubectl -n argocd get applications)"
  if [ -z "$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)" ] \
     && [ "$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null)" = LoadBalancer ]; then
    warn "Traefik has no load balancer IP: minikube -> 'minikube tunnel'; homelab -> Cilium L2 (ciliumLB) or NodePort"
  fi
  return 1
}

# access_box "<comps>" <domain>: URL + login of every enabled component with a UI whose secret exists.
# Passwords are never printed: only the command that reads them. Plain text (saved to kstack-access.txt).
secret_exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }
# secret_cmd NS NAME KEY: the command that prints that secret value
secret_cmd() { printf "kubectl -n %s get secret %s -o jsonpath='{.data.%s}' | base64 -d" "$1" "$2" "$3"; }
access_box() {
  local comps=$1 d=$2 count=0
  # print_login TITLE HOST USER PASSWORD_CMD
  print_login() {
    printf ' %-10s %s\n' "$1" "https://$2.$d"
    printf ' %-10s %-9s %s\n' "" "user" "$3" "" "password" "$4"
    count=$((count + 1))
  }
  # Only show logins that already work (their secret exists)
  if secret_exists argocd argocd-initial-admin-secret; then
    print_login ArgoCD argocd admin "$(secret_cmd argocd argocd-initial-admin-secret password)"
  fi
  if component_enabled infisical "$comps" && secret_exists infisical infisical-admin; then
    print_login Infisical infisical "$(secret_cmd infisical infisical-admin email)" \
      "$(secret_cmd infisical infisical-admin password)"
  fi
  if component_enabled monitoring "$comps" && secret_exists monitoring grafana-admin; then
    print_login Grafana grafana admin "$(secret_cmd monitoring grafana-admin admin-password)"
  fi
  if [ "$count" -eq 0 ]; then
    echo " No login ready yet: kubectl -n argocd get applications"
  fi
  return 0
}

# ./install.sh password <argocd|infisical|grafana>
password() {
  local ns name key value user=""
  case "${1:-}" in
    argocd) ns=argocd name=argocd-initial-admin-secret key=password ;;
    infisical) ns=infisical name=infisical-admin key=password ;;
    grafana) ns=monitoring name=grafana-admin key=admin-password ;;
    *) die "usage: $(self_cmd) password <argocd|infisical|grafana>" ;;
  esac
  value=$(kubectl -n "$ns" get secret "$name" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null) \
    || value=""
  [ -n "$value" ] || die "$1 is not ready yet (no secret $ns/$name): wait for ArgoCD (kubectl -n argocd get applications)"
  if [ "$1" = infisical ]; then
    user=$(kubectl -n "$ns" get secret "$name" -o jsonpath='{.data.email}' 2>/dev/null | base64 -d 2>/dev/null) \
      || user=""
    printf 'user:     %s\npassword: %s\n' "$user" "$value"
  else
    printf '%s\n' "$value"
  fi
}

# Local clusters (kind, minikube): the tunnel to run, before the apps deploy
access_hint() {
  local node_info tunnel sudo=""
  node_info=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels}{.items[0].spec.providerID}' 2>/dev/null) || true
  if [ "$(uname -s)" = Darwin ] || [ -n "${WINDIR:-}" ]; then
    sudo=1   # macOS / Windows: cloud-provider-kind runs with sudo there
  fi
  case "$node_info" in
    *kind://*) tunnel="${sudo:+sudo }cloud-provider-kind --gateway-channel disabled" ;;
    *minikube.k8s.io*) tunnel="minikube tunnel" ;;
    *) return 0 ;;
  esac
  clear_busy_line
  rule "Before you start"
  printf ' %sIn another terminal, keep this running (gives Traefik its IP):%s\n    %s%s%s\n' \
    "$COLOR_TITLE" "$COLOR_RESET" "$COLOR_BOLD" "$tunnel" "$COLOR_RESET"
  # The browser then reaches Traefik from the node's Docker network, not from your public IP
  local node_ip docker_net
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || true
  docker_net="${node_ip%.*}.0/24"
  if [[ ",$(allowed_ips)," == *",$docker_net,"* ]]; then
    return 0
  fi
  if [ -n "${KSTACK_DEMO:-}" ]; then
    printf ' %sPlatform UIs answer 403 to that tunnel: run the demo again with%s\n    %sKSTACK_ALLOWED_IPS=%s%s\n' \
      "$COLOR_TITLE" "$COLOR_RESET" "$COLOR_BOLD" "$docker_net" "$COLOR_RESET"
  else
    printf ' %sPlatform UIs answer 403 to that tunnel: add it to global.platformAccess.allowedIPs (cluster.yaml)%s\n    %s%s%s\n' \
      "$COLOR_TITLE" "$COLOR_RESET" "$COLOR_BOLD" "$docker_net" "$COLOR_RESET"
  fi
}

# At the end: the /etc/hosts line with the real Traefik IP, if the URLs do not resolve to it
hosts_hint() {
  local d ip entry hosts=""
  d=$(cfg .global.domain)
  case "$d" in
    *.sslip.io|*.nip.io) ;;
    *) return 0 ;;
  esac
  ip=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || true
  [ -n "$ip" ] || return 0
  [ "$(getent hosts "argocd.$d" 2>/dev/null | awk '{print $1; exit}')" != "$ip" ] || return 0
  # entry = <component>:<hostname>; argocd is always deployed
  for entry in argocd infisical:infisical monitoring:grafana; do
    if [ "$entry" != argocd ] && ! component_enabled "${entry%%:*}" "$(enabled_components)"; then
      continue
    fi
    hosts+=" ${entry#*:}.$d"
  done
  rule "Open the URLs"
  printf ' %sAdd them to /etc/hosts:%s\n    %secho "%s%s" | sudo tee -a /etc/hosts%s\n' \
    "$COLOR_TITLE" "$COLOR_RESET" "$COLOR_BOLD" "$ip" "$hosts" "$COLOR_RESET"
}

summary() {
  flush_warns
  hosts_hint
  local d out
  d=$(cfg .global.domain)
  rule Access
  out=$(access_box "$(enabled_components)" "$d")
  printf '%s\n' "$out" >"$ROOT/kstack-access.txt"
  printf '%s\n' "$out" | sed -E "s/^ ([A-Za-z]+)/ ${COLOR_BOLD}\1${COLOR_RESET}/"   # titles in bold
  printf '\n %sSaved to %s (no passwords)%s\n' "$COLOR_DIM" "$ROOT/kstack-access.txt" "$COLOR_RESET"
  printf ' Platform UIs only answer: %s (global.platformAccess.allowedIPs)\n' "$(allowed_ips)"
  if [ -z "${KSTACK_DEMO:-}" ]; then
    echo " To change anything: edit cluster.yaml or helm/, then git push"
  fi
  return 0
}

# ---------------------------------------------------------------- configure (first run)
# When cluster.yaml still has example.com (or ArgoCD does not follow this clone yet), or with `configure`:
# ask a few questions, write cluster.yaml + argocd/, show the diff, commit and push. Never in demo mode (try.sh).

# can_prompt: is there a terminal to ask questions on (also true under curl | bash)?
can_prompt() { { : </dev/tty; } 2>/dev/null; }
# ask CURRENT "Question" DEFAULT: prints the answer on stdout, the question goes to the terminal (stderr).
# No question if CURRENT is set, with KSTACK_YES=1 or without a terminal: prints CURRENT, else DEFAULT.
#   KSTACK_IP=$(ask "$KSTACK_IP" "IP of the cluster" "$ip")
ask() {
  local current=$1 question=$2 default=$3 answer=""
  if [ -n "$current" ] || [ -n "${KSTACK_YES:-}" ] || ! can_prompt; then
    printf '%s' "${current:-$default}"
    return 0
  fi
  read -r -p "  ${COLOR_PROMPT}${question}${COLOR_STDERR_RESET} [${default:-none}]: " answer </dev/tty || true
  printf '%s' "${answer:-$default}"
}
setup() {
  local force=${1:-} origin branch
  [ -z "${KSTACK_DEMO:-}" ] || return 0
  origin=${KSTACK_REPO:-$(git -C "$ROOT" remote get-url origin 2>/dev/null)} \
    || die "run install.sh from a git clone of your fork"
  origin=$(sed -E "s#://[^@/]+@#://#" <<<"${origin%.git}.git")   # never write credentials into Git
  case "$origin" in
    git@github.com:*) origin="https://github.com/${origin#git@github.com:}" ;;
  esac
  branch=${KSTACK_BRANCH:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)}
  # Already configured for this clone: install as is
  if [ -z "$force" ] && [ "$(repo)" = "$origin" ] && [ "$(rev)" = "$branch" ] \
     && [ -n "$(cfg .global.domain)" ] && [ "$(cfg .global.domain)" != example.com ]; then
    log "configured (cluster.yaml: $(cfg .global.domain)): installing as is (./install.sh configure to change)"
    return 0
  fi
  if is_public_repo "$origin"; then
    die "that is our public repo: use your fork (or scripts/try.sh for a demo)"
  fi
  kubectl version --request-timeout=10s >/dev/null 2>&1 || die "no reachable cluster in the current kubectl context.
  No Kubernetes? k3s in one minute: curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"--disable traefik\" sh -"
  log "context: $(kubectl config current-context). Configuring $origin ($branch). A few questions (Enter = default):"
  local ip
  ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  KSTACK_EMAIL=${KSTACK_EMAIL:-}
  KSTACK_DOMAIN=$(ask "${KSTACK_DOMAIN:-}" "Domain (empty = <ip>.sslip.io with self-signed certs)" "")
  if [ -n "$KSTACK_DOMAIN" ]; then
    KSTACK_EMAIL=$(ask "$KSTACK_EMAIL" "Email for Let's Encrypt (empty = self-signed)" "")
  fi
  KSTACK_IP=$(ask "${KSTACK_IP:-}" "IP your browser uses to reach the cluster (Traefik node / LB)" "$ip")
  KSTACK_CILIUM=$(ask "${KSTACK_CILIUM:-}" "Install Cilium (only for a cluster created WITHOUT a CNI) true/false" false)
  # Platform UIs: who may open them (README "Platform access"). Guess: public node IP = public, private = home
  local pub exposure=public proxies="" allowed given=${KSTACK_EXPOSURE:-}
  pub=$(public_ip)
  case "$ip" in
    "$pub") ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) exposure=home ;;
  esac
  if [ -n "$(cfg '.traefik.ports.websecure.forwardedHeaders.trustedIPs[0]')" ]; then
    exposure=proxy
  fi
  pub=${pub:+$pub/32}
  KSTACK_EXPOSURE=$(ask "${KSTACK_EXPOSURE:-}" "How is the cluster reached? public (IP on the Internet) | proxy (Cloudflare, tunnel, load balancer) | home (LAN behind a box)" "$exposure")
  case "$KSTACK_EXPOSURE" in
    public) allowed=$pub ;;
    proxy)
      KSTACK_PROXY=$(ask "${KSTACK_PROXY:-}" "Proxy: cloudflare | cloudflare-tunnel (cloudflared in the cluster) | its IPs/CIDRs (comma-separated)" \
        "$(yq -r '.traefik.ports.websecure.forwardedHeaders.trustedIPs // [] | join(",") | select(. != "") // "cloudflare"' "$CONFIG")")
      case "$KSTACK_PROXY" in
        cloudflare) proxies=$(cloudflare_ips) ;;
        cloudflare-tunnel) proxies=$(pod_cidr) ;;
        *) proxies=$KSTACK_PROXY ;;
      esac
      allowed=$pub ;;
    home) allowed=$(lan_cidr "$ip")${pub:+,$pub} ;;
    *) die "KSTACK_EXPOSURE: public, proxy or home (got: $KSTACK_EXPOSURE)" ;;
  esac
  # ./install.sh configure: keep the current list unless KSTACK_EXPOSURE is given
  if [ -z "$given" ] && [ -n "$(allowed_ips)" ]; then
    allowed=$(allowed_ips)
  fi
  KSTACK_ALLOWED_IPS=$(ask "${KSTACK_ALLOWED_IPS:-}" "Public IPs/CIDRs of your browser allowed on ArgoCD, Grafana, Infisical (comma-separated)" "$allowed")
  local dom=${KSTACK_DOMAIN:-${KSTACK_IP}.sslip.io} tls=selfsigned issuer=selfsigned-ca
  if [ -n "$KSTACK_EMAIL" ]; then
    tls=letsencrypt-http01
    issuer=letsencrypt
  fi

  # 1. cluster.yaml: your settings
  D="$dom" T="$tls" I="$issuer" E="${KSTACK_EMAIL:-admin@$dom}" yq -i '
    .global.domain = strenv(D) | .global.tls.issuer = strenv(T) | .global.issuer = strenv(I) |
    .global.tls.email = strenv(E)' "$CONFIG"
  A="$KSTACK_ALLOWED_IPS" yq -i '
    .global.platformAccess.allowedIPs = (strenv(A) | split(",") | map(sub(" "; "")) | map(select(. != "")))' "$CONFIG"
  P="$proxies" yq -i '
    .traefik.ports.websecure.forwardedHeaders.trustedIPs = (strenv(P) | split(",") | map(select(. != "")))' "$CONFIG"
  if [ -z "$KSTACK_ALLOWED_IPS" ]; then
    warn "no allowed IP: the platform UIs answer 403 to everyone. Set global.platformAccess.allowedIPs in cluster.yaml"
  fi
  # 2. argocd/: ArgoCD follows your fork
  R="$origin" B="$branch" yq -i '.spec.source.repoURL = strenv(R) | .spec.source.targetRevision = strenv(B)' "$APP"
  local f
  for f in "$ROOT"/argocd/applications/*/appset.yaml; do
    R="$origin" B="$branch" yq -i '
      (.spec.generators[0] | select(has("git")) | .git) |= (.repoURL = strenv(R) | .revision = strenv(B)) |
      .spec.template.spec.source.repoURL = strenv(R) | .spec.template.spec.source.targetRevision = strenv(B)' "$f"
  done
  # 3. components: entries of the list in the platform ApplicationSet
  if [ "$KSTACK_CILIUM" = true ] && ! component_enabled cilium "$(enabled_components)"; then
    yq -i '.spec.generators[0].list.elements += [{"app": "cilium", "namespace": "kube-system", "stage": "1"}]' "$APPSET"
    IP="$KSTACK_IP" yq -i '.cilium.k8sServiceHost = strenv(IP) | .cilium.k8sServicePort = 6443 |
      .cilium.ipam = {"mode": "cluster-pool", "operator": {"clusterPoolIPv4PodCIDRList": ["10.42.0.0/16"]}}' "$CONFIG"
  fi
  # k3s & co already run a metrics-server: do not deploy ours
  if foreign_metrics_server; then
    yq -i 'del(.spec.generators[0].list.elements[] | select(.app == "metrics-server"))' "$APPSET"
  fi
  if [ "$tls" != selfsigned ]; then
    log "Let's Encrypt HTTP-01: *.$dom must point to $KSTACK_IP, port 80 open from the Internet"
  fi

  # 4. commit and push (after a confirmation when someone is at the terminal)
  if [ -z "$(git -C "$ROOT" status --porcelain -- cluster.yaml argocd)" ]; then
    ok "nothing to change"
    return 0
  fi
  log "changes to your fork:"
  git -C "$ROOT" --no-pager diff --stat
  git -C "$ROOT" --no-pager diff -- cluster.yaml argocd/app-of-apps.yaml
  if [ -z "${KSTACK_YES:-}" ] && can_prompt; then
    local answer
    read -r -p "  ${COLOR_PROMPT}Commit and push to ${origin} (${branch})?${COLOR_STDERR_RESET} [Y/n]: " answer </dev/tty || true
    case "${answer:-y}" in
      y|Y|yes) ;;
      *) die "nothing pushed. Your edited fork is in $ROOT: push it, then run ./install.sh there" ;;
    esac
  fi
  git -C "$ROOT" -c user.name="${GIT_AUTHOR_NAME:-kinops}" -c user.email="${GIT_AUTHOR_EMAIL:-kinops@localhost}" \
    commit -qm "kinops: my settings (domain $dom)" -- cluster.yaml argocd || die "git commit failed"
  local auth=()
  if [ -n "${GIT_TOKEN:-}" ]; then
    auth=(-c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | b64)")
  fi
  # ${auth[@]+...}: expands to nothing when auth is empty (bash 3.2 + set -u)
  git -C "$ROOT" ${auth[@]+"${auth[@]}"} push -q origin "HEAD:$branch" \
    || die "push failed (write access to $origin? set GIT_USERNAME/GIT_TOKEN). Your edited fork is in $ROOT"
  ok "pushed: $(git -C "$ROOT" log -1 --format='%h %s')"
}

# ---------------------------------------------------------------- uninstall
# Removes everything the platform created, deterministically (does not depend on ArgoCD pruning:
# ArgoCD manages itself and can take itself down first). Asks first: the data in the volumes is lost.
# Kept: CRDs (deleting one deletes its objects in the whole cluster) and Cilium (the cluster's CNI).
# delete_objects "<components>" NAMESPACE RESOURCE...: objects of these components (NAMESPACE empty = cluster-wide),
# found by their ArgoCD tracking annotation or their Helm instance label
delete_objects() {
  local comps=$1 ns=$2 r o app inst
  shift 2
  for r in "$@"; do
    while IFS='|' read -r o app inst; do
      if component_enabled "${app%%:*}" "$comps" || component_enabled "$inst" "$comps"; then
        kubectl ${ns:+-n "$ns"} delete "$r" "$o" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      fi
    done < <(kubectl ${ns:+-n "$ns"} get "$r" -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.annotations.argocd\.argoproj\.io/tracking-id}|{.metadata.labels.app\.kubernetes\.io/instance}{"\n"}{end}' 2>/dev/null)
  done
}
uninstall() {
  local releases=() namespaces=() existing=() first=() d r n o comps answer corefile
  local operators=(cert-manager cnpg-system external-secrets openebs)
  kubectl version --request-timeout=10s >/dev/null 2>&1 || die "no reachable cluster in the current kubectl context"
  # Components and their namespaces: the platform ApplicationSet list + helm/apps/*
  while read -r r; do releases+=("$r"); done < <(yq -r '.spec.generators[0].list.elements[].app' "$APPSET" | grep -vx cilium)
  while read -r n; do namespaces+=("$n"); done < <(yq -r '.spec.generators[0].list.elements[].namespace' "$APPSET" \
    | grep -vx kube-system | sort -u)
  for d in "$ROOT"/helm/apps/*/; do
    if [ -d "$d" ]; then
      namespaces+=("$(basename "$d")")
      releases+=("$(basename "$d")")
    fi
  done
  comps=$(printf '%s\n' "${releases[@]}")

  # 0. Show what goes away, then ask (KSTACK_YES=1: no question)
  for n in "${namespaces[@]}"; do
    if kubectl get ns "$n" >/dev/null 2>&1; then
      existing+=("$n")
    fi
  done
  log "This deletes, on $(kubectl config current-context):"
  # One row per namespace: its pods and its volumes (PVCs: their data is lost)
  printf '    %s%-22s %6s %6s %10s%s\n' "$COLOR_BOLD" NAMESPACE PODS PVCS STORAGE "$COLOR_RESET"
  for n in ${existing[@]+"${existing[@]}"}; do
    printf '    %-22s %6s %s\n' "$n" "$(kubectl -n "$n" get pods --no-headers 2>/dev/null | grep -c .)" \
      "$(kubectl -n "$n" get pvc --no-headers -o custom-columns=S:.spec.resources.requests.storage 2>/dev/null \
        | awk '{v=$1+0; if ($1 ~ /Mi$/) v/=1024; if ($1 ~ /Ti$/) v*=1024; n++; t+=v}
               END {if (n) printf "%6d %8.1fGi", n, t; else printf "%6d %10s", 0, "-"}')"
  done
  if [ ${#existing[@]} -eq 0 ]; then
    printf '    %-22s\n' none
  fi
  printf '    + ArgoCD, its Applications and the cluster-wide objects of the components\n'
  printf '    %skept: CRDs, Cilium%s\n' "$COLOR_DIM" "$COLOR_RESET"
  answer=$(ask "${KSTACK_YES:+yes}" "Delete all of this? yes/no" no)
  case "$answer" in
    y|Y|yes) ;;
    *) die "nothing removed" ;;
  esac

  # 1. Stop ArgoCD: no controller left to re-create or prune anything, then orphan every
  #    Application (finalizers cleared, workloads stay) and remove ArgoCD itself.
  log "removing ArgoCD"
  kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0 >/dev/null 2>&1 || true
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null 2>&1 || true
  for o in $(kubectl -n argocd get applications,applicationsets,appprojects -o name 2>/dev/null); do
    kubectl -n argocd patch "$o" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  kubectl -n argocd delete applications,applicationsets,appprojects --all --wait=false >/dev/null 2>&1 || true
  helm uninstall argocd -n argocd --wait >/dev/null 2>&1 || true

  # 2. Webhooks and API services first: left without their pods they break the API server for those kinds
  #    (and the namespace deletion below). Then what the components put in kube-system (metrics-server...).
  delete_objects "$comps" "" validatingwebhookconfigurations mutatingwebhookconfigurations apiservices
  delete_objects "$comps" kube-system deploy ds sts svc sa cm secret role rolebinding pdb servicemonitors

  # 3. Namespaces (and their PVCs): workloads first, while the operators (CloudNativePG, External Secrets,
  #    cert-manager, OpenEBS) still run and can clear the finalizers of their own resources; then the operators.
  for n in "${namespaces[@]}"; do
    case " ${operators[*]} " in
      *" $n "*) ;;
      *) first+=("$n") ;;
    esac
  done
  log "deleting namespaces: ${first[*]}"
  kubectl delete ns "${first[@]}" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
  log "deleting operators: ${operators[*]}"
  kubectl delete ns "${operators[@]}" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true

  # 4. Anything still stuck on a finalizer (its operator is already gone): clear it, then delete again
  for n in "${namespaces[@]}"; do
    kubectl get ns "$n" >/dev/null 2>&1 || continue
    for r in $(kubectl api-resources --namespaced --verbs=list -o name 2>/dev/null); do
      for o in $(kubectl -n "$n" get "$r" -o name 2>/dev/null); do
        kubectl -n "$n" patch "$o" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      done
    done
  done
  kubectl delete ns "${namespaces[@]}" --ignore-not-found --wait=true --timeout=2m >/dev/null 2>&1 \
    || warn "some namespaces are still terminating: kubectl get ns"

  # 5. The other cluster-wide objects of the components (ClusterRoles, ClusterIssuers, StorageClasses...), CRDs kept
  log "removing the cluster-wide objects of the components"
  # shellcheck disable=SC2046 # one resource name per word
  delete_objects "$comps" "" $(kubectl api-resources --namespaced=false --verbs=list,delete -o name 2>/dev/null \
    | grep -vxE 'customresourcedefinitions.apiextensions.k8s.io|namespaces|persistentvolumes')

  # 6. Volumes whose claim was in those namespaces and that are still there (Retain policy, provisioner gone)
  for o in $(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null); do
    component_enabled "${o#*|}" "$(printf '%s\n' "${namespaces[@]}")" || continue
    kubectl patch pv "${o%%|*}" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    kubectl delete pv "${o%%|*}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done

  # 7. CoreDNS: drop the *.<domain> -> Traefik rewrite added by internal_dns
  corefile=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null) || true
  if grep -q "platform internal-dns" <<<"$corefile"; then
    kubectl -n kube-system create configmap coredns --from-literal=Corefile="$(grep -v "platform internal-dns" <<<"$corefile")" \
      --dry-run=client -o yaml | kubectl -n kube-system apply -f - >/dev/null 2>&1 || true
    kubectl -n kube-system rollout restart deployment coredns >/dev/null 2>&1 || true
  fi
  rm -f "$ROOT/kstack-access.txt"
  ok "done (kept: CRDs, Cilium)"
}

command -v yq >/dev/null 2>&1 || die "yq (mikefarah, v4) is required"
case "$CMD" in
  doctor) doctor ;;
  install) header; setup; QUIET=1; install ;;
  configure) header; setup force; QUIET=1; install ;;
  uninstall) uninstall ;;
  password) password "$PW_APP" ;;
esac
