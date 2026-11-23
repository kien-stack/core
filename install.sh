#!/usr/bin/env bash
# kien/stack Essential installer (free, Apache-2.0). Run it from a clone of YOUR fork (or curl .../scripts/install.sh | bash).
# First run (cluster.yaml still on example.com) asks a few questions, writes cluster.yaml + argocd/, commits and pushes.
#   ./install.sh             configure if needed, then install (default)
#   ./install.sh configure   ask the questions again, commit, push, install
#   ./install.sh doctor      check the cluster and the repo
#   ./install.sh uninstall   ArgoCD apps, then ArgoCD (keeps namespaces/PVCs)
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
PACK=essential
CMD=install
ARGOCD_TIMEOUT=${ARGOCD_TIMEOUT:-0}   # seconds to wait for the apps, 0 = until ready

# colors: only on a TTY, honour NO_COLOR and TERM=dumb (bash 3.2 safe)
kc() { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
# shellcheck disable=SC2034
if kc 1; then C_H=$'\033[1;36m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_D=$'\033[2m' C_0=$'\033[0m'; else C_H='' C_G='' C_Y='' C_R='' C_D='' C_0=''; fi
if kc 2; then E_R=$'\033[1;31m' E_Q=$'\033[1;36m' E_0=$'\033[0m'; else E_R='' E_Q='' E_0=''; fi
log()  { printf '%s[kien/stack]%s %s\n' "${C_H}" "${C_0}" "$*"; }
ok()   { printf '  %sOK%s   %s\n' "${C_G}" "${C_0}" "$*"; }
warn() { printf '  %sWARN%s %s\n' "${C_Y}" "${C_0}" "$*"; }
ko()   { printf '  %sKO%s   %s\n' "${C_R}" "${C_0}" "$*"; }
die()  { printf '%s[kien/stack] ERROR:%s %s\n' "${E_R}" "${E_0}" "$*" >&2; exit 1; }

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    doctor|install|configure|uninstall) CMD=$1 ;;
    --pack) [ "${2:-}" = "$PACK" ] || die "this repo installs the $PACK pack"; shift ;;
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
  [ -n "${KSTACK_DEMO:-}" ] || case "$r" in *kien-stack/essential*|*dedsxc/kien-stack-essential*) warn "argocd/app-of-apps.yaml still points to our public repo: put your fork's URL there (and in argocd/applications/*/appset.yaml)" ;; esac
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
  local name=$1 ns=$2; shift 2
  # GitHub-hosted chart downloads sometimes fail (5xx): retry before giving up
  local i; for i in 1 2 3 4 5; do
    helm dependency update "$ROOT/helm/platform/$name" >/dev/null 2>&1 && break
    [ "$i" -lt 5 ] || helm dependency update "$ROOT/helm/platform/$name" >/dev/null
    warn "downloading the $name chart failed, retrying ($i/4)"; sleep $((i * 10))
  done
  helm upgrade --install "$name" "$ROOT/helm/platform/$name" -n "$ns" --create-namespace \
    -f "$CONFIG" "$@" --wait --timeout 10m >/dev/null
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
  if has seaweedfs; then
    local ak sk; ak="$(randpw 20)"; sk="$(randpw 40)"
    ensure_secret seaweedfs seaweedfs-s3 "seaweedfs_s3_config={\"identities\":[{\"name\":\"admin\",\"credentials\":[{\"accessKey\":\"$ak\",\"secretKey\":\"$sk\"}],\"actions\":[\"Admin\",\"Read\",\"List\",\"Tagging\",\"Write\"]}]}" "accessKey=$ak" "secretKey=$sk"
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
  local comps; comps=$(enabled_components)
  log "Pack $PACK -> ArgoCD will deploy: $(tr '\n' ' ' <<<"$comps")"
  doctor || die "doctor failed: fix the prerequisites above"

  bootstrap_secrets "$comps"
  internal_dns

  if grep -qx cilium <<<"$comps"; then
    log "Installing Cilium (CNI, before everything else; then managed by ArgoCD)"
    # LB pool / L2 policy CRDs only exist once the Cilium operator runs: ArgoCD adds them right after.
    helm_bootstrap cilium kube-system --set ciliumLB.enabled=false
    kubectl wait --for=condition=Ready nodes --all --timeout=5m >/dev/null
    ok "Cilium ready, nodes Ready"
  fi

  log "Installing ArgoCD (Helm, then self-managed by ArgoCD)"
  # The HTTPRoute needs the Gateway API CRDs, installed later by the traefik component:
  # ArgoCD creates it when it takes itself over
  helm_bootstrap argocd argocd --set argo-cd.server.httproute.enabled=false
  ok "ArgoCD ready"
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

  log "kubectl apply -f argocd/app-of-apps.yaml (as committed in Git)"
  kubectl apply -f "$APP" >/dev/null
  ok "ArgoCD now syncs from $(repo) ($(rev)): push to change the platform"

  # Logins first: URLs and password commands are known now, the apps can take a while
  summary
  trap 'echo; log "Stopped waiting (ArgoCD keeps deploying). Logins: $ROOT/kstack-access.txt"; exit 0' INT
  if wait_apps "$comps"; then trap - INT; ok "Logins above, also in $ROOT/kstack-access.txt"; else trap - INT; return 1; fi
}

wait_apps() {
  # ArgoCD deploys every app in parallel; this shows each app's status until all are ready (no time limit by
  # default, ARGOCD_TIMEOUT=<seconds> to cap it). Ctrl+C is safe: ArgoCD keeps deploying.
  # Terminal: one line per app, redrawn in place only when a status changes. CI/pipe: one line per change.
  local comps=$1 timeout=${ARGOCD_TIMEOUT%s} apps a n=0 w=12 start=$SECONDS
  apps="app-of-apps $comps"
  for a in $apps; do n=$((n + 1)); if [ ${#a} -ge $w ]; then w=$(( ${#a} + 2 )); fi; done
  local tty=""; if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then tty=1; fi
  log "Deploying $n apps with ArgoCD (Ctrl+C is safe: ArgoCD keeps going)"
  local rc=0 prev="" el=0 j st data out row pending
  local -a last=()
  while :; do
    data=$'\n'$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
    el=$(( SECONDS - start )); out=""; pending=0; j=0
    for a in $apps; do
      j=$((j + 1)); st=""
      if [[ "$data" == *$'\n'"$a="* ]]; then st=${data#*$'\n'"$a="}; st=${st%%$'\n'*}; fi
      case "$st" in
        Synced/Healthy) row="${C_G}OK${C_0}" ;;
        */Degraded)     row="${C_Y}Degraded${C_0}"; pending=$((pending + 1)) ;;
        ""|/|*/)        row="Pending"; pending=$((pending + 1)) ;;
        */Healthy)      row="Syncing"; pending=$((pending + 1)) ;;
        *)              row="${st#*/}"; pending=$((pending + 1)) ;;
      esac
      if [ -n "$tty" ]; then
        printf -v row '  %-*s %s\033[K\n' "$w" "$a" "$row"; out+=$row
      elif [ "${last[j]:-}" != "$row" ]; then
        printf '  %-*s %s\n' "$w" "$a" "$row"; last[j]=$row
      fi
    done
    if [ -n "$tty" ] && [ "$out" != "$prev" ]; then
      if [ -n "$prev" ]; then printf '\033[%dA' "$n"; fi
      printf '%s' "$out"; prev=$out
    fi
    if [ "$pending" -eq 0 ]; then break; fi
    if [ "${timeout:-0}" -gt 0 ] && [ "$el" -ge "$timeout" ]; then rc=1; break; fi
    sleep 2
  done
  if [ "$rc" -eq 0 ]; then ok "all $n apps are ready ($(( el / 60 )) min $(( el % 60 )) s)"; return 0; fi
  warn "still not ready after ${timeout}s (ArgoCD keeps deploying: kubectl -n argocd get applications)"
  if [ -z "$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)" ] \
     && [ "$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null)" = LoadBalancer ]; then
    warn "Traefik has no load balancer IP: minikube -> 'minikube tunnel'; homelab -> Cilium L2 (ciliumLB) or NodePort"
  fi
  return 1
}

# access_box "<comps>" <domain>: URL / user / password of every enabled component with a UI (charts in helm/).
# Passwords are never printed: only the kubectl command that reads them. Standalone: access_box "$(enabled_components)" my.domain
access_box() {
  local comps=$1 d=$2 l w=0 bar
  local -a L=("kien/stack access ($d)" "")
  sec() { printf "kubectl -n %s get secret %s -o jsonpath='{.data.%s}' | base64 -d" "$1" "$2" "$3"; }
  L+=("ArgoCD     https://argocd.$d" "  user      admin" "  password  $(sec argocd argocd-initial-admin-secret password)")
  if grep -qx infisical <<<"$comps"; then
    L+=("" "Infisical  https://infisical.$d" "  user      $(sec infisical infisical-admin email)" "  password  $(sec infisical infisical-admin password)")
  fi
  if grep -qx monitoring <<<"$comps"; then
    L+=("" "Grafana    https://grafana.$d" "  user      admin" "  password  $(sec monitoring grafana-admin admin-password)")
  fi
  for l in "${L[@]}"; do [ ${#l} -le $w ] || w=${#l}; done
  printf -v bar '%*s' $((w + 2)) ''; bar=${bar// /─}
  printf '┌%s┐\n' "$bar"; printf '│ %-*s │\n' "$w" "${L[0]}"; printf '├%s┤\n' "$bar"
  for l in "${L[@]:2}"; do printf '│ %-*s │\n' "$w" "$l"; done
  printf '└%s┘\n' "$bar"
}

summary() {
  local d out; d=$(cfg .global.domain)
  printf '%s[kien/stack] Access (apps keep deploying below):%s\n' "${C_G}" "${C_0}"
  out=$(access_box "$(enabled_components)" "$d")
  printf '%s\n' "$out" | tee "$ROOT/kstack-access.txt"
  printf '%s  Saved to kstack-access.txt (no passwords)%s\n' "${C_D}" "${C_0}"
  [ -n "${KSTACK_DEMO:-}" ] || echo "  To change anything: edit cluster.yaml or helm/, then git push"
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
  case "$origin" in *kien-stack/essential*|*dedsxc/kien-stack-essential*) die "that is our public repo: use your fork (or scripts/try.sh for a demo)" ;; esac
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
    yq -i '.spec.generators[0].list.elements += [{"app": "cilium", "namespace": "kube-system"}]' "$APPSET"
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
  git -C "$ROOT" -c user.name="${GIT_AUTHOR_NAME:-kien-stack}" -c user.email="${GIT_AUTHOR_EMAIL:-kien-stack@localhost}" \
    commit -qm "kien/stack: my settings (domain $dom)" -- cluster.yaml argocd || die "git commit failed"
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
  install) setup; install ;;
  configure) setup force; install ;;
  uninstall) uninstall ;;
esac
