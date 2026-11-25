#!/usr/bin/env bash
# kinops Community installer (free, Apache-2.0). Run it from a clone of YOUR fork (or curl .../scripts/install.sh | bash).
# First run (cluster.yaml still on example.com) asks a few questions, writes cluster.yaml + argocd/, commits and pushes.
#   ./install.sh             configure if needed, then install (default)
#   ./install.sh configure   ask the questions again, commit, push, install
#   ./install.sh doctor      check the cluster and the repo
#   ./install.sh uninstall   ArgoCD apps, then ArgoCD (keeps namespaces/PVCs)
#   ./install.sh password argocd|infisical|grafana   print a login (once its app is deployed)
# KSTACK_VERBOSE=1 shows every step in detail.
# Everything it uses is in Git, nothing is generated:
#   cluster.yaml             your settings (domain, TLS...), passed to every chart
#   argocd/app-of-apps.yaml  the repo/branch ArgoCD follows (same URL in argocd/applications/*/appset.yaml)
#   argocd/applications/platform/appset.yaml   components + namespace: comment out an entry to disable it
# After that, ArgoCD applies whatever you push.
# Non-interactive: KSTACK_DOMAIN, KSTACK_EMAIL, KSTACK_IP, KSTACK_CILIUM, KSTACK_YES=1 (KSTACK_REPO/KSTACK_BRANCH: default = this clone).
# Optional environment variables (secrets, never stored in Git):
#   GIT_USERNAME / GIT_TOKEN          private GitOps repo (HTTPS)
#   DNS01_API_TOKEN                   if global.tls.issuer=letsencrypt-dns01
#   EXTERNAL_DNS_API_TOKEN            if the external-dns component is enabled
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$ROOT/cluster.yaml"
APP="$ROOT/argocd/app-of-apps.yaml"
APPSET="$ROOT/argocd/applications/platform/appset.yaml"
PACK=community
CMD=install
ARGOCD_TIMEOUT=${ARGOCD_TIMEOUT:-0}   # seconds to wait for the apps, 0 = until ready

# colors: only on a TTY, honour NO_COLOR and TERM=dumb (bash 3.2 safe)
kc() { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
# shellcheck disable=SC2034
if kc 1; then C_H=$'\033[1;36m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_D=$'\033[2m' C_B=$'\033[1m' C_0=$'\033[0m'; else C_H='' C_G='' C_Y='' C_R='' C_D='' C_B='' C_0=''; fi
if kc 2; then E_R=$'\033[1;31m' E_Q=$'\033[1;36m' E_0=$'\033[0m'; else E_R='' E_Q='' E_0=''; fi
TTY=""; if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then TTY=1; fi
# QUIET=1 (install): details only with KSTACK_VERBOSE=1; warnings and errors are always shown
QUIET="" PEND=""
verbose() { [ -z "$QUIET" ] || [ -n "${KSTACK_VERBOSE:-}" ]; }
clr()  { if [ -n "$PEND" ]; then printf '\r\033[K'; PEND=""; fi; }
log()  { verbose || return 0; clr; printf '%s[kinops]%s %s\n' "${C_H}" "${C_0}" "$*"; }
ok()   { verbose || return 0; clr; printf '  %sOK%s   %s\n' "${C_G}" "${C_0}" "$*"; }
WARNS=()
# warn: shown at once outside install; during install collected and shown in a "Warnings" section
warn() { if [ -n "$QUIET" ]; then WARNS+=("$*"); return 0; fi; clr; printf '  %sWARN%s %s\n' "${C_Y}" "${C_0}" "$*"; }
flush_warns() {
  [ ${#WARNS[@]} -gt 0 ] || return 0
  local w; rule Warnings
  for w in "${WARNS[@]}"; do printf ' %s⚠%s %s\n' "${C_Y}" "${C_0}" "$w"; done
  WARNS=()
}
ko()   { clr; printf '  %sKO%s   %s\n' "${C_R}" "${C_0}" "$*"; }
die()  { clr; printf '%s[kinops] ERROR:%s %s\n' "${E_R}" "${E_0}" "$*" >&2; exit 1; }
# step NAME TEXT: one line per install step; busy NAME TEXT: same line while it runs (TTY only)
busy() { [ -z "$TTY" ] || { clr; printf ' %s◌%s %-12s %s' "${C_D}" "${C_0}" "$1" "$2"; PEND=1; }; }
step() { clr; printf ' %s✓%s %-12s %s\n' "${C_G}" "${C_0}" "$1" "$2"; }
rule() { local b; printf -v b '%*s' $(( 50 - ${#1} )) ''; printf '\n %s─── %s %s%s\n' "${C_D}" "$1" "${b// /─}" "${C_0}"; }
version() {
  local v; v=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null) \
    || v=$(sed -n 's/^## \[\{0,1\}\([0-9][0-9.]*\).*/v\1/p' "$ROOT/CHANGELOG.md" 2>/dev/null | head -1) || true
  printf '%s' "$v"
}
header() { local v; v=$(version); printf '\n %skinops%s · %s%s\n\n' "${C_B}" "${C_0}" "$PACK" "${v:+ ${v}}"; }
# how to run this installer from the user's shell (try.sh / scripts/install.sh set KSTACK_PWD)
self_cmd() {
  local p="$ROOT/install.sh"
  if [ "${KSTACK_PWD:-$PWD}" = "$ROOT" ]; then p=./install.sh
  else
    local t='~' r=$ROOT; case "$r" in "$HOME"/*) r="$t${r#"$HOME"}" ;; esac
    p="cd $r && ./install.sh"
  fi
  printf '%s' "$p"
}

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    doctor|install|configure|uninstall) CMD=$1 ;;
    password) CMD=password; PW_APP=${2:-}; [ $# -lt 2 ] || shift ;;
    --pack) case "${2:-}" in "$PACK"|essential) ;; *) die "this repo installs the $PACK pack" ;; esac; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done

cfg()  { yq -r "$1 // \"\"" "$CONFIG"; }
repo() { yq -r '.spec.source.repoURL' "$APP"; }
rev()  { yq -r '.spec.source.targetRevision' "$APP"; }

# macOS has no `timeout` nor `base64 -w0` (GNU): portable equivalents
run_timeout() { local t=$1; shift; if command -v timeout >/dev/null; then timeout "$t" "$@"; elif command -v gtimeout >/dev/null; then gtimeout "$t" "$@"; else "$@"; fi; }
b64() { base64 | tr -d '\n'; }
randpw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-24}" || true; }

# Components ArgoCD will deploy: the entries of the platform ApplicationSet list, + helm/apps/*.
enabled_components() {
  local d
  yq -r '.spec.generators[0].list.elements[].app' "$APPSET"
  for d in "$ROOT"/helm/apps/*/; do [ -d "$d" ] && basename "$d"; done
  return 0
}
# k3s (and some distros) already run a metrics-server in kube-system with an immutable selector.
foreign_metrics_server() {
  [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]
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

# ---------------------------------------------------------------- doctor
doctor() {
  local fail=0 b comps; comps=$(enabled_components)
  log "Checking prerequisites"
  for b in kubectl helm git yq; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b found"; else ko "$b not found in PATH"; fail=1; fi
  done
  [ "$fail" -eq 0 ] || { ko "missing tools"; return 1; }

  local ctx; ctx=$(kubectl config current-context 2>/dev/null || true)
  if kubectl version --request-timeout=10s >/dev/null 2>&1; then
    ok "cluster reachable (context: ${ctx:-?}, $(kubectl version -o json 2>/dev/null | yq -r '.serverVersion.gitVersion'))"
  else ko "cluster unreachable (context: ${ctx:-none})"; fail=1; fi
  if [ "$fail" -eq 0 ]; then
    if kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then ok "cluster-admin rights"; else ko "cluster-admin rights required"; fail=1; fi
    local mem
    mem=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | awk '{ v=$1; if (v ~ /Ki$/) s+=v/1048576; else if (v ~ /Mi$/) s+=v/1024; else if (v ~ /Gi$/) s+=v; else s+=v/1073741824 } END {print int(s)}')
    if [ "$mem" -ge 3 ]; then ok "allocatable memory: ${mem} Gi"; else warn "allocatable memory ${mem} Gi: >= 6 GB recommended"; fi
    if grep -qx metrics-server <<<"$comps" && foreign_metrics_server; then
      ko "this cluster already runs a metrics-server: remove the metrics-server entry in $APPSET"; fail=1
    fi
    if grep -qx cilium <<<"$comps" && ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
      local cni; cni=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Eo '^(kindnet|flannel|kube-flannel|calico|canal|weave|kube-router|aws-node|antrea)' | head -1 || true)
      if [ -n "$cni" ]; then ko "cilium is enabled but this cluster already has a CNI ($cni): remove the cilium entry in $APPSET again"; fail=1
      else ok "no CNI found: Cilium will be installed"; fi
    fi
  fi

  local r; r=$(repo)
  [ -n "${KSTACK_DEMO:-}" ] || case "$r" in *kinopshq/core*|*kien-stack/core*|*kien-stack/essential*|*dedsxc/kien-stack-essential*) warn "argocd/app-of-apps.yaml still points to our public repo: put your fork's URL there (and in argocd/applications/*/appset.yaml)" ;; esac
  if grep -rq "repoURL: $r" "$ROOT"/argocd/applications/*/appset.yaml && [ "$(grep -rh 'repoURL:' "$ROOT"/argocd/applications/*/appset.yaml | sort -u | wc -l)" -eq 1 ]; then
    ok "ApplicationSets follow the same repo as app-of-apps"
  else ko "argocd/applications/*/appset.yaml must use the same repoURL as argocd/app-of-apps.yaml ($r)"; fail=1; fi
  if git_ls_remote "$r" >/dev/null 2>&1; then ok "Git repo reachable: $r ($(rev))"
  else ko "Git repo unreachable: $r (private repo? set GIT_USERNAME/GIT_TOKEN)"; fail=1; fi

  # ArgoCD deploys what is in Git, not this folder: local edits must be committed and pushed
  # try.sh (demo) edits cluster.yaml / argocd/ locally on purpose and pins our public release: skip the Git checks
  if [ -n "${KSTACK_DEMO:-}" ]; then
    ok "demo mode: local settings, ArgoCD follows the public release"
  elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C "$ROOT" status --porcelain -- cluster.yaml argocd helm 2>/dev/null)" ]; then
      ko "uncommitted changes in cluster.yaml / argocd/ / helm/: ArgoCD only sees Git. Commit and push them: git -C $ROOT commit -am 'my settings' && git -C $ROOT push"; fail=1
    else
      local remote_sha; remote_sha=$(git_ls_remote "$r" "refs/heads/$(rev)" 2>/dev/null | awk -v b="refs/heads/$(rev)" '$2==b{print $1}')
      local head_sha; head_sha=$(git -C "$ROOT" rev-parse HEAD)
      if [ -n "$remote_sha" ] && [ "$remote_sha" != "$head_sha" ]; then
        if git -C "$ROOT" merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
          ko "local commits not pushed to $r ($(rev)): ArgoCD only sees Git. Run: git -C $ROOT push"; fail=1
        else warn "$r ($(rev)) differs from this folder: ArgoCD will deploy what is in Git"; fi
      fi
    fi
  fi

  local domain; domain=$(cfg .global.domain)
  if [ -z "$domain" ] || [ "$domain" = example.com ]; then ko "set global.domain in cluster.yaml (no domain? <node-ip>.sslip.io)"; fail=1
  elif getent hosts "argocd.$domain" >/dev/null 2>&1; then ok "DNS: argocd.$domain -> $(getent hosts "argocd.$domain" | awk '{print $1; exit}')"
  else warn "argocd.$domain does not resolve (fine if external-dns will create it; otherwise create *.$domain)"; fi

  case "$(cfg .global.tls.issuer)" in
    letsencrypt-dns01)
      if [ -n "${DNS01_API_TOKEN:-}" ] || kubectl -n cert-manager get secret "$(cfg .global.tls.dns01.secretName)" >/dev/null 2>&1; then ok "DNS01 token"
      else ko "DNS01_API_TOKEN required"; fail=1; fi ;;
    letsencrypt-http01) warn "HTTP01: *.$domain must point to the Traefik load balancer, port 80 open from the Internet" ;;
    selfsigned) ok "self-signed certificates" ;;
    *) ko "invalid global.tls.issuer"; fail=1 ;;
  esac
  if [ "$fail" -eq 0 ]; then log "doctor: OK"; else log "doctor: some prerequisites are missing"; fi
  return "$fail"
}

# ---------------------------------------------------------------- install
# Install helm/platform/<name> once with Helm, exactly like ArgoCD will (values.yaml + cluster.yaml);
# same release name, so ArgoCD takes it over.
helm_bootstrap() {
  local name=$1 ns=$2 out; shift 2
  # GitHub-hosted chart downloads sometimes fail (5xx): retry before giving up
  local i; for i in 1 2 3 4 5; do
    out=$(helm dependency update "$ROOT/helm/platform/$name" 2>&1) && break
    if [ "$i" -eq 5 ]; then printf '%s\n' "$out" | tail -20 >&2; die "downloading the $name chart failed"; fi
    warn "downloading the $name chart failed, retrying ($i/4)"; sleep $((i * 10))
  done
  if ! out=$(helm upgrade --install "$name" "$ROOT/helm/platform/$name" -n "$ns" --create-namespace \
    -f "$CONFIG" "$@" --wait --timeout 10m 2>&1); then
    clr; printf '%s\n' "$out" | tail -20 >&2; die "helm install of $name failed (details above)"
  fi
  if [ -n "${KSTACK_VERBOSE:-}" ]; then clr; printf '%s\n' "$out"; fi
}


ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# ensure_secret ns name [type] key=value...  (never overwrites an existing secret)
ensure_secret() {
  local ns=$1 name=$2; shift 2
  local type=generic
  case "${1:-}" in --type=*) type=${1#--type=}; shift ;; esac
  ensure_ns "$ns"
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then ok "secret $ns/$name already exists"; return; fi
  local args=() kv
  for kv in "$@"; do args+=("--from-literal=$kv"); done
  kubectl -n "$ns" create secret generic "$name" --type="$type" "${args[@]}" >/dev/null
  ok "secret $ns/$name created"
}

bootstrap_secrets() {
  local comps=$1 provider issuer
  has() { grep -qx "$1" <<<"$comps"; }
  provider=$(cfg .global.secrets.provider); issuer=$(cfg .global.tls.issuer)
  log "Bootstrap secrets"
  if [ "$issuer" = letsencrypt-dns01 ] && [ -n "${DNS01_API_TOKEN:-}" ]; then
    ensure_secret cert-manager "$(cfg .global.tls.dns01.secretName)" "$(cfg .global.tls.dns01.secretKey)=$DNS01_API_TOKEN"
  fi
  if has external-dns && [ -n "${EXTERNAL_DNS_API_TOKEN:-}" ]; then
    ensure_secret external-dns external-dns-api-token "api-token=$EXTERNAL_DNS_API_TOKEN"
  fi
  # Platform secrets: generated locally (random), never committed. Your app secrets: Infisical, project 'kubernetes',
  # one folder per app, read through the ClusterSecretStores infisical-dev / infisical-staging / infisical-prod.
  if has litellm; then
    local mk; mk="sk-$(randpw 32)"
    ensure_secret litellm litellm-masterkey "masterkey=$mk"
    ensure_secret litellm litellm-providers "PROXY_MASTER_KEY=$mk" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
      "GEMINI_API_KEY=${GEMINI_API_KEY:-}" "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}" "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}"
  fi
  has renovate && ensure_secret renovate renovate-env "RENOVATE_TOKEN=${RENOVATE_TOKEN:-}"
  return 0
}

# In-cluster resolution of *.<domain> -> Traefik. Apps call each other over https://<app>.<domain>
# (OIDC with Authentik...). On minikube, k3d or behind NAT the public IP is often not reachable from the pods:
# CoreDNS then answers with the Traefik service. On by default for sslip.io / nip.io domains,
# KSTACK_INTERNAL_DNS=1|0 to force. Idempotent. CoreDNS belongs to the distribution: bootstrap step, not ArgoCD.
internal_dns() {
  local d want cf re rule
  d=$(cfg .global.domain)
  want=${KSTACK_INTERNAL_DNS:-}
  if [ -z "$want" ]; then case "$d" in *.sslip.io|*.nip.io) want=1 ;; *) want=0 ;; esac; fi
  [ "$want" = 1 ] || return 0
  if ! cf=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null) || [ -z "$cf" ]; then
    warn "no kube-system/coredns ConfigMap: resolve *.$d to traefik.traefik.svc yourself"; return 0
  fi
  if grep -q "platform internal-dns" <<<"$cf"; then ok "CoreDNS: *.$d -> Traefik (already set)"; return 0; fi
  re=${d//./\\.}
  rule="    rewrite name regex (.*)\\.$re traefik.traefik.svc.cluster.local answer auto # platform internal-dns"
  cf=$(awk -v r="$rule" '!done && /^[[:space:]]*kubernetes[[:space:]]/ {print r; done=1} {print}' <<<"$cf")
  if ! grep -q "platform internal-dns" <<<"$cf"; then warn "CoreDNS: no kubernetes block, rewrite not added"; return 0; fi
  kubectl -n kube-system create configmap coredns --from-literal=Corefile="$cf" --dry-run=client -o yaml \
    | kubectl -n kube-system apply -f - >/dev/null 2>&1
  kubectl -n kube-system rollout restart deployment coredns >/dev/null 2>&1 || true
  ok "CoreDNS: *.$d -> Traefik inside the cluster (KSTACK_INTERNAL_DNS=0 to skip)"
}

install() {
  local comps n; comps=$(enabled_components); n=$(( $(printf '%s\n' "$comps" | grep -c .) + 1 ))
  log "Pack $PACK -> ArgoCD will deploy: $(tr '\n' ' ' <<<"$comps")"
  busy Checks "cluster, Git repo..."
  doctor || die "checks failed: fix the problems above (details: ./install.sh doctor)"
  bootstrap_secrets "$comps"
  internal_dns
  step Checks "cluster OK, Git repo reachable"

  if grep -qx cilium <<<"$comps"; then
    busy Cilium "installing (CNI, before everything else)..."
    # LB pool / L2 policy CRDs only exist once the Cilium operator runs: ArgoCD adds them right after.
    helm_bootstrap cilium kube-system --set ciliumLB.enabled=false
    kubectl wait --for=condition=Ready nodes --all --timeout=5m >/dev/null || die "nodes not Ready after Cilium: kubectl get nodes"
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
  local r; r=$(repo); r=${r#*://}; r=${r%.git}
  step GitOps "syncing from ${r} ($(rev))"

  tunnel_hint
  hosts_hint
  flush_warns
  rule Deploy
  printf ' %s apps%s\n' "$n" "${C_D} (Ctrl+C is safe: ArgoCD keeps going)${C_0}"
  trap 'clr; printf "\n\n Stopped waiting: ArgoCD keeps deploying (kubectl -n argocd get applications)\n"; summary; exit 0' INT
  local rc=0; wait_apps "$comps" || rc=1
  trap - INT
  summary
  return $rc
}

wait_apps() {
  # ArgoCD deploys every app in parallel; this shows each app's status until all are ready (no time limit by
  # default, ARGOCD_TIMEOUT=<seconds> to cap it). Ctrl+C is safe: ArgoCD keeps deploying.
  # Terminal: one line per app, redrawn in place when a status changes. CI/pipe: one line per change.
  local comps=$1 timeout=${ARGOCD_TIMEOUT%s} apps a n=0 w=8 start=$SECONDS
  apps="app-of-apps $comps"
  for a in $apps; do n=$((n + 1)); if [ ${#a} -gt $w ]; then w=${#a}; fi; done
  local rc=0 prev="" lines=0 el=0 j st data out cell sym pending
  local -a last=()
  while :; do
    data=$'\n'$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
    el=$(( SECONDS - start )); out=""; pending=0; j=0
    for a in $apps; do
      j=$((j + 1)); st=""
      if [[ "$data" == *$'\n'"$a="* ]]; then st=${data#*$'\n'"$a="}; st=${st%%$'\n'*}; fi
      case "$st" in
        Synced/Healthy) sym="${C_G}✓${C_0}" st=ready ;;
        */Degraded)     sym="${C_Y}⚠${C_0}" st=degraded; pending=$((pending + 1)) ;;
        ""|/|*/)        sym="${C_D}◌${C_0}" st=pending; pending=$((pending + 1)) ;;
        */Healthy)      sym="${C_D}◌${C_0}" st=syncing; pending=$((pending + 1)) ;;
        *)              sym="${C_D}◌${C_0}" st=$(tr '[:upper:]' '[:lower:]' <<<"${st#*/}"); pending=$((pending + 1)) ;;
      esac
      if [ -n "$TTY" ]; then
        printf -v cell '   %s %-*s %s\033[K\n' "$sym" "$w" "$a" "$st"; out+=$cell
      elif [ "${last[j]:-}" != "$st" ]; then
        printf '   %s %-*s %s\n' "$sym" "$w" "$a" "$st"; last[j]=$st
      fi
    done
    if [ -n "$TTY" ] && [ "$out" != "$prev" ]; then
      if [ "$lines" -gt 0 ]; then printf '\033[%dA' "$lines"; fi
      printf '%s' "$out"; prev=$out; lines=$n
    fi
    if [ "$pending" -eq 0 ]; then break; fi
    if [ "${timeout:-0}" -gt 0 ] && [ "$el" -ge "$timeout" ]; then rc=1; break; fi
    sleep 2
  done
  if [ "$rc" -eq 0 ]; then printf ' %s✓%s All apps ready (%s min %s s)\n' "${C_G}" "${C_0}" $(( el / 60 )) $(( el % 60 )); return 0; fi
  warn "still not ready after ${timeout}s (ArgoCD keeps deploying: kubectl -n argocd get applications)"
  if [ -z "$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)" ] \
     && [ "$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null)" = LoadBalancer ]; then
    warn "Traefik has no load balancer IP: minikube -> 'minikube tunnel'; homelab -> Cilium L2 (ciliumLB) or NodePort"
  fi
  return 1
}

# access_box "<comps>" <domain>: URL + login of every enabled component with a UI whose secret exists.
# Passwords are never printed: only the command that reads them. Plain text (saved to kstack-access.txt).
access_box() {
  local comps=$1 d=$2 n=0
  has() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }   # only show logins that already work
  sec() { printf "kubectl -n %s get secret %s -o jsonpath='{.data.%s}' | base64 -d" "$1" "$2" "$3"; }
  row() { printf ' %-10s %s\n' "$1" "https://$2.$d"; printf ' %-10s %-9s %s\n' "" "user" "$3" "" "password" "$4"; n=$((n + 1)); }
  if has argocd argocd-initial-admin-secret; then row ArgoCD argocd admin "$(sec argocd argocd-initial-admin-secret password)"; fi
  if grep -qx infisical <<<"$comps" && has infisical infisical-admin; then
    row Infisical infisical "$(sec infisical infisical-admin email)" "$(sec infisical infisical-admin password)"; fi
  if grep -qx monitoring <<<"$comps" && has monitoring grafana-admin; then
    row Grafana grafana admin "$(sec monitoring grafana-admin admin-password)"; fi
  [ "$n" -gt 0 ] || echo " No login ready yet: kubectl -n argocd get applications"
  return 0
}

# ./install.sh password <argocd|infisical|grafana>
password() {
  local ns name key v u=""
  case "${1:-}" in
    argocd) ns=argocd name=argocd-initial-admin-secret key=password ;;
    infisical) ns=infisical name=infisical-admin key=password ;;
    grafana) ns=monitoring name=grafana-admin key=admin-password ;;
    *) die "usage: $(self_cmd) password <argocd|infisical|grafana>" ;;
  esac
  v=$(kubectl -n "$ns" get secret "$name" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null) || v=""
  [ -n "$v" ] || die "$1 is not ready yet (no secret $ns/$name): wait for ArgoCD (kubectl -n argocd get applications)"
  if [ "$1" = infisical ]; then
    u=$(kubectl -n "$ns" get secret "$name" -o jsonpath='{.data.email}' 2>/dev/null | base64 -d 2>/dev/null) || u=""
    printf 'user:     %s\npassword: %s\n' "$u" "$v"
  else printf '%s\n' "$v"; fi
}

hosts_hint() {
  local d h c; d=$(cfg .global.domain)
  case "$d" in *.sslip.io|*.nip.io) ;; *) return 0 ;; esac   # real domain: DNS does the job
  [ "$(uname -s)" = Darwin ] || [ -n "${WINDIR:-}" ] || return 0   # Linux reaches the node IP directly
  h="argocd.$d"
  for c in infisical:infisical monitoring:grafana; do grep -qx "${c%%:*}" <<<"$(enabled_components)" && h="$h ${c#*:}.$d"; done
  warn "No domain: on macOS the cluster IP is not reachable, add the URLs to /etc/hosts:
     echo \"127.0.0.1 $h\" | sudo tee -a /etc/hosts
   (after uninstall: sudo sed -i '' '/$d/d' /etc/hosts)"
}

tunnel_hint() {
  local l; l=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels}{.items[0].spec.providerID}' 2>/dev/null) || true
  case "$l" in
    *minikube.k8s.io*) warn 'minikube: run "minikube tunnel" in another terminal, or the URLs will not answer' ;;
    *kind://*) warn "kind: Traefik needs a LoadBalancer IP (cloud-provider-kind), or the URLs will not answer" ;;
  esac
}

summary() {
  flush_warns
  local d out; d=$(cfg .global.domain)
  rule Access
  out=$(access_box "$(enabled_components)" "$d")
  printf '%s\n' "$out" >"$ROOT/kstack-access.txt"
  printf '%s\n' "$out" | sed -E "s/^ ([A-Za-z]+)/ ${C_B}\1${C_0}/"
  printf '\n %sSaved to %s (no passwords)%s\n' "${C_D}" "$ROOT/kstack-access.txt" "${C_0}"
  [ -n "${KSTACK_DEMO:-}" ] || echo " To change anything: edit cluster.yaml or helm/, then git push"
  return 0
}

# ---------------------------------------------------------------- configure (first run)
# When cluster.yaml still has example.com (or ArgoCD does not follow this clone yet), or with `configure`:
# ask a few questions, write cluster.yaml + argocd/, show the diff, commit and push. Never in demo mode (try.sh).
ask() { # ask VAR "question" default
  local v=${!1:-}
  if [ -n "$v" ] || [ -n "${KSTACK_YES:-}" ] || ! { : </dev/tty; } 2>/dev/null; then printf -v "$1" %s "${v:-$3}"; return; fi
  read -r -p "  ${E_Q}${2}${E_0} [${3:-none}]: " v </dev/tty || true; printf -v "$1" %s "${v:-$3}"
}
setup() {
  local force=${1:-} origin branch
  [ -z "${KSTACK_DEMO:-}" ] || return 0
  origin=${KSTACK_REPO:-$(git -C "$ROOT" remote get-url origin 2>/dev/null)} || die "run install.sh from a git clone of your fork"
  origin=$(sed -E "s#://[^@/]+@#://#" <<<"${origin%.git}.git")   # never write credentials into Git
  case "$origin" in git@github.com:*) origin="https://github.com/${origin#git@github.com:}" ;; esac
  branch=${KSTACK_BRANCH:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)}
  if [ -z "$force" ] && [ "$(repo)" = "$origin" ] && [ "$(rev)" = "$branch" ] \
     && [ -n "$(cfg .global.domain)" ] && [ "$(cfg .global.domain)" != example.com ]; then
    log "configured (cluster.yaml: $(cfg .global.domain)): installing as is (./install.sh configure to change)"; return 0
  fi
  case "$origin" in *kinopshq/core*|*kien-stack/core*|*kien-stack/essential*|*dedsxc/kien-stack-essential*) die "that is our public repo: use your fork (or scripts/try.sh for a demo)" ;; esac
  kubectl version --request-timeout=10s >/dev/null 2>&1 || die "no reachable cluster in the current kubectl context.
  No Kubernetes? k3s in one minute: curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"--disable traefik\" sh -"
  log "context: $(kubectl config current-context). Configuring $origin ($branch). A few questions (Enter = default):"
  local ip; ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  KSTACK_DOMAIN=${KSTACK_DOMAIN:-}; KSTACK_EMAIL=${KSTACK_EMAIL:-}; KSTACK_IP=${KSTACK_IP:-}; KSTACK_CILIUM=${KSTACK_CILIUM:-}
  ask KSTACK_DOMAIN "Domain (empty = <ip>.sslip.io with self-signed certs)" ""
  [ -z "$KSTACK_DOMAIN" ] || ask KSTACK_EMAIL "Email for Let's Encrypt (empty = self-signed)" ""
  ask KSTACK_IP "IP your browser uses to reach the cluster (Traefik node / LB)" "$ip"
  ask KSTACK_CILIUM "Install Cilium (only for a cluster created WITHOUT a CNI) true/false" false
  local dom=${KSTACK_DOMAIN:-${KSTACK_IP}.sslip.io} tls=selfsigned is=selfsigned-ca
  [ -z "$KSTACK_EMAIL" ] || { tls=letsencrypt-http01; is=letsencrypt; }

  # 1. cluster.yaml: your settings
  D="$dom" T="$tls" I="$is" E="${KSTACK_EMAIL:-admin@$dom}" yq -i '
    .global.domain = strenv(D) | .global.tls.issuer = strenv(T) | .global.issuer = strenv(I) |
    .global.tls.email = strenv(E)' "$CONFIG"
  # 2. argocd/: ArgoCD follows your fork
  R="$origin" B="$branch" yq -i '.spec.source.repoURL = strenv(R) | .spec.source.targetRevision = strenv(B)' "$APP"
  local f; for f in "$ROOT"/argocd/applications/*/appset.yaml; do
    R="$origin" B="$branch" yq -i '(.spec.generators[0] | select(has("git")) | .git) |= (.repoURL = strenv(R) | .revision = strenv(B)) |
      .spec.template.spec.source.repoURL = strenv(R) | .spec.template.spec.source.targetRevision = strenv(B)' "$f"
  done
  # 3. components: entries of the list in the platform ApplicationSet
  if [ "$KSTACK_CILIUM" = true ] && ! grep -qx cilium <<<"$(enabled_components)"; then
    yq -i '.spec.generators[0].list.elements += [{"app": "cilium", "namespace": "kube-system", "stage": "1"}]' "$APPSET"
    IP="$KSTACK_IP" yq -i '.cilium.k8sServiceHost = strenv(IP) | .cilium.k8sServicePort = 6443 |
      .cilium.ipam = {"mode": "cluster-pool", "operator": {"clusterPoolIPv4PodCIDRList": ["10.42.0.0/16"]}}' "$CONFIG"
  fi
  # k3s & co already run a metrics-server: do not deploy ours
  if foreign_metrics_server; then
    yq -i 'del(.spec.generators[0].list.elements[] | select(.app == "metrics-server"))' "$APPSET"
  fi
  [ "$tls" = selfsigned ] || log "Let's Encrypt HTTP-01: *.$dom must point to $KSTACK_IP, port 80 open from the Internet"

  if [ -z "$(git -C "$ROOT" status --porcelain -- cluster.yaml argocd)" ]; then ok "nothing to change"; return 0; fi
  log "changes to your fork:"; git -C "$ROOT" --no-pager diff --stat; git -C "$ROOT" --no-pager diff -- cluster.yaml argocd/app-of-apps.yaml
  if [ -z "${KSTACK_YES:-}" ] && { : </dev/tty; } 2>/dev/null; then
    local a; read -r -p "  ${E_Q}Commit and push to ${origin} (${branch})?${E_0} [Y/n]: " a </dev/tty || true
    case "${a:-y}" in y|Y|yes) ;; *) die "nothing pushed. Your edited fork is in $ROOT: push it, then run ./install.sh there" ;; esac
  fi
  git -C "$ROOT" -c user.name="${GIT_AUTHOR_NAME:-kinops}" -c user.email="${GIT_AUTHOR_EMAIL:-kinops@localhost}" \
    commit -qm "kinops: my settings (domain $dom)" -- cluster.yaml argocd || die "git commit failed"
  local auth=()
  [ -z "${GIT_TOKEN:-}" ] || auth=(-c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | b64)")
  git -C "$ROOT" ${auth[@]+"${auth[@]}"} push -q origin "HEAD:$branch" || die "push failed (write access to $origin? set GIT_USERNAME/GIT_TOKEN). Your edited fork is in $ROOT"
  ok "pushed: $(git -C "$ROOT" log -1 --format='%h %s')"
}

# ---------------------------------------------------------------- uninstall
# Order matters: ArgoCD manages itself, so stop the self-management first or it deletes its own
# controller and the remaining Applications hang on their finalizers.
uninstall() {
  log "Removing the platform (ArgoCD apps, then ArgoCD); namespaces, CRDs and PVCs are kept"
  unfin() { kubectl -n argocd patch application "$1" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; }
  unfin app-of-apps; kubectl -n argocd delete application app-of-apps --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n argocd delete applicationsets --all --cascade=orphan >/dev/null 2>&1 || true
  unfin argocd; kubectl -n argocd delete application argocd --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n argocd delete applications --all --wait=true --timeout=5m || {
    warn "some apps did not finish pruning: forcing"
    for a in $(kubectl -n argocd get applications -o name 2>/dev/null); do unfin "${a#*/}"; done; }
  kubectl -n argocd delete appprojects platform apps --ignore-not-found >/dev/null 2>&1 || true
  helm uninstall argocd -n argocd --wait 2>/dev/null || true
  ok "done (delete namespaces/PVCs with kubectl if you want)"
}

command -v yq >/dev/null 2>&1 || die "yq (mikefarah, v4) is required"
case "$CMD" in
  doctor) doctor ;;
  install) header; setup; QUIET=1; install ;;
  configure) header; setup force; QUIET=1; install ;;
  uninstall) uninstall ;;
  password) password "$PW_APP" ;;
esac
