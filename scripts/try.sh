#!/usr/bin/env bash
# kinops Community TRY: a disposable demo on your current cluster, zero questions.
#   curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/try.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/try.sh | bash -s uninstall
#     removes everything the demo created (volumes included, asks first), then ~/kinops-try
# Uses the public repo on main (ArgoCD follows main; pin a release with KSTACK_REF=vX.Y.Z),
# <node-ip>.sslip.io and self-signed certs. For real use: https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh
# Overrides: KSTACK_IP, KSTACK_REF, KSTACK_ALLOWED_IPS. Requires kubectl, helm, git (yq is fetched if missing).
set -euo pipefail
KSTACK_PWD=$PWD   # where the user runs this: install.sh prints the commands relative to it
REPO=${KSTACK_SOURCE:-https://github.com/kinopshq/core}
REF=${KSTACK_REF:-main}
DIR=${KSTACK_DIR:-$HOME/kinops-try}

# Colors: only on a terminal, honour NO_COLOR and TERM=dumb (bash 3.2 safe).
# COLOR_* are for stdout; COLOR_FATAL / COLOR_STDERR_RESET for stderr (errors).
use_color() { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
if use_color 1; then
  COLOR_TITLE=$'\033[1;36m' COLOR_DIM=$'\033[2m' COLOR_RESET=$'\033[0m'
else
  COLOR_TITLE='' COLOR_DIM='' COLOR_RESET=''
fi
if use_color 2; then
  COLOR_FATAL=$'\033[1;31m' COLOR_STDERR_RESET=$'\033[0m'
else
  COLOR_FATAL='' COLOR_STDERR_RESET=''
fi
log() { printf '%s[kinops]%s %s\n' "$COLOR_TITLE" "$COLOR_RESET" "$*"; }
die() { printf '%serror:%s %s\n' "$COLOR_FATAL" "$COLOR_STDERR_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisites
for tool in kubectl helm git; do
  command -v "$tool" >/dev/null \
    || die "$tool is required (https://helm.sh/docs/intro/install, https://kubernetes.io/docs/tasks/tools)"
done
if ! command -v yq >/dev/null; then
  mkdir -p "$DIR/.bin"
  export PATH="$DIR/.bin:$PATH"
  if ! [ -x "$DIR/.bin/yq" ]; then
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case $arch in
      x86_64) arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
    esac
    log "fetching yq ($os/$arch)"
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${arch}" -o "$DIR/.bin/yq"
    chmod +x "$DIR/.bin/yq"
  fi
fi
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "no reachable cluster in the current kubectl context.
  No Kubernetes? k3s in one minute: curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"--disable traefik\" sh -"

# Our public repo at $REF, in $DIR/src (updated if already there)
if [ -d "$DIR/src/.git" ]; then
  git -C "$DIR/src" fetch -q origin "$REF" && git -C "$DIR/src" checkout -qf FETCH_HEAD
else
  mkdir -p "$DIR"
  git -c advice.detachedHead=false clone -q --depth 1 -b "$REF" "$REPO" "$DIR/src"
fi
cd "$DIR/src"
APPSET=argocd/applications/platform/appset.yaml

# ---------------------------------------------------------------- uninstall
# install.sh uninstall removes everything the platform created (it asks first), then the demo files go too.
if [ "${1:-}" = uninstall ]; then
  log "uninstall: the platform, then $DIR (the demo files)"
  bash install.sh uninstall
  case "$DIR" in
    ""|/|"$HOME"|"$HOME/") die "refusing to delete $DIR" ;;
  esac
  cd /
  rm -rf -- "$DIR"
  log "deleted $DIR"
  exit 0
fi

# ---------------------------------------------------------------- demo settings (local only, never pushed)
ip=${KSTACK_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}
dom=$ip.sslip.io
if [ -n "${KSTACK_VERBOSE:-}" ]; then
  log "demo on context $(kubectl config current-context), https://*.$dom, release $REF"
fi
# A demo has no fork: ArgoCD reads OUR public repo at $REF (its cluster.yaml says example.com).
# So, and ONLY in this demo, the root Application pins $REF and overrides global.domain.
# A real install has none of this: ./install.sh writes your settings into your fork.
D="$dom" yq -i '.global.domain = strenv(D)' cluster.yaml
# Platform UIs (ArgoCD, Grafana, Infisical) only answer these IPs: KSTACK_ALLOWED_IPS, else this machine's public IP.
allowed=${KSTACK_ALLOWED_IPS:-}
if [ -z "$allowed" ]; then
  public=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [[ "$public" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    allowed="$public/32"
  fi
fi
A="$allowed" yq -i '.global.platformAccess.allowedIPs = (strenv(A) | split(",") | map(sub(" "; "")) | map(select(. != "")))' cluster.yaml
allowed_json=$(yq -o=json -I=0 '.global.platformAccess.allowedIPs' cluster.yaml)
# k3s & co already run a metrics-server: do not deploy ours
if [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]; then
  yq -i 'del(.spec.generators[0].list.elements[] | select(.app == "metrics-server"))' "$APPSET"
fi
# Kustomize patches applied by the root Application to the ApplicationSets it creates (JSON patches):
#   - every ApplicationSet: its apps follow $REF and get global.domain = <ip>.sslip.io + global.platformAccess
#   - "apps": its Git generator reads $REF
#   - "platform": the component list edited above (metrics-server maybe removed)
components=$(yq -o=json -I=0 '.spec.generators[0].list.elements' "$APPSET")
patches=$(cat <<YAML
- target: {kind: ApplicationSet}
  patch:
    - {op: replace, path: /spec/template/spec/source/targetRevision, value: "$REF"}
    - {op: add, path: /spec/template/spec/source/helm/valuesObject, value: {global: {domain: "$dom", platformAccess: {allowedIPs: $allowed_json}}}}
- target: {kind: ApplicationSet, name: apps}
  patch:
    - {op: replace, path: /spec/generators/0/git/revision, value: "$REF"}
- target: {kind: ApplicationSet, name: platform}
  patch:
    - {op: replace, path: /spec/generators/0/list/elements, value: $components}
YAML
)
# Kustomize wants each "patch" as a string: to_json turns each list of operations into one.
REF="$REF" PATCHES="$patches" yq -i '
  .spec.source.targetRevision = strenv(REF) |
  .spec.source.kustomize.patches = (strenv(PATCHES) | from_yaml | (.. style="") | .[].patch |= to_json)
' argocd/app-of-apps.yaml

# ---------------------------------------------------------------- install, then next steps
KSTACK_DEMO=1 KSTACK_PWD=$KSTACK_PWD bash install.sh install || exit $?
raw=https://raw.githubusercontent.com/kinopshq/core/main/scripts
# section TITLE WIDTH: "─── TITLE ─────" (WIDTH dashes after the title)
section() {
  local dashes
  dashes=$(printf '%*s' "$2" '')
  printf '\n %s─── %s %s%s\n' "$COLOR_DIM" "$1" "${dashes// /─}" "$COLOR_RESET"
}
section "Next steps" 39
printf ' %-16s %s\n' "1. Real install" "curl -fsSL $raw/install.sh | bash" "2. More packs" "https://kinops.dev"
section Remove 43
printf ' %s\n' "curl -fsSL $raw/try.sh | bash -s uninstall"
