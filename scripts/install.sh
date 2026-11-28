#!/usr/bin/env bash
# kinops Community INSTALL: the real, free install on your cluster.
#   curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash -s uninstall
# Before: fork https://github.com/kinopshq/core (you need push access to your fork).
# Clones YOUR fork, then runs its ./install.sh (questions on first run, commit + push, install).
# Same as: git clone <your fork> && cd <it> && ./install.sh
# Non-interactive: KSTACK_REPO, KSTACK_BRANCH, KSTACK_DOMAIN, KSTACK_EMAIL, KSTACK_IP, KSTACK_ALLOWED_IPS,
# KSTACK_CILIUM, KSTACK_YES=1; GIT_USERNAME/GIT_TOKEN for a private repo. Requires kubectl, helm, git.
set -euo pipefail
UPSTREAM=https://github.com/kinopshq/core
DIR=${KSTACK_DIR:-$HOME/kinops}

# Colors: only on a terminal, honour NO_COLOR and TERM=dumb (bash 3.2 safe).
# COLOR_* are for stdout; COLOR_FATAL / COLOR_STDERR_RESET for stderr (errors).
use_color() { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
if use_color 1; then
  COLOR_TITLE=$'\033[1;36m' COLOR_RESET=$'\033[0m'
else
  COLOR_TITLE='' COLOR_RESET=''
fi
if use_color 2; then
  COLOR_FATAL=$'\033[1;31m' COLOR_STDERR_RESET=$'\033[0m'
else
  COLOR_FATAL='' COLOR_STDERR_RESET=''
fi
log() { printf '%s[kinops]%s %s\n' "$COLOR_TITLE" "$COLOR_RESET" "$*"; }
die() { printf '%serror:%s %s\n' "$COLOR_FATAL" "$COLOR_STDERR_RESET" "$*" >&2; exit 1; }

# can_prompt: is there a terminal to ask questions on (also true under curl | bash)?
can_prompt() { { : </dev/tty; } 2>/dev/null; }
# ask CURRENT "Question" DEFAULT: prints the answer on stdout, the question goes to the terminal (stderr).
# No question if CURRENT is set, with KSTACK_YES=1 or without a terminal: prints CURRENT, else DEFAULT.
ask() {
  local current=$1 question=$2 default=$3 answer=""
  if [ -n "$current" ] || [ -n "${KSTACK_YES:-}" ] || ! can_prompt; then
    printf '%s' "${current:-$default}"
    return 0
  fi
  read -r -p "  $question [${default:-none}]: " answer </dev/tty || true
  printf '%s' "${answer:-$default}"
}
# Our public repo (and its former names): a real install needs your own fork.
# Same list in install.sh (this script runs through curl | bash, it cannot share code with it).
is_public_repo() {
  case "$1" in
    *kinopshq/core*|*kien-stack/core*|*kien-stack/essential*|*dedsxc/kien-stack-essential*) return 0 ;;
    *) return 1 ;;
  esac
}

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

SRC="$DIR/repo"
if [ "${1:-}" = uninstall ]; then
  # uninstall only needs the script: your clone if any, else ours
  if [ ! -f "$SRC/install.sh" ]; then
    SRC=$(mktemp -d)
    git clone -q --depth 1 "${KSTACK_SOURCE:-$UPSTREAM}" "$SRC"
  fi
  exec bash "$SRC/install.sh" "$@"
fi

# ---------------------------------------------------------------- your fork
KSTACK_REPO=$(ask "${KSTACK_REPO:-}" "Your fork of kinopshq/core, HTTPS URL" "")
if [ -z "$KSTACK_REPO" ]; then
  die "a GitOps repo is required: fork $UPSTREAM first (or run https://raw.githubusercontent.com/kinopshq/core/main/scripts/try.sh for a demo)"
fi
if is_public_repo "$KSTACK_REPO"; then
  die "that is our public repo: use your fork (or try.sh for a demo)"
fi
case "$KSTACK_REPO" in
  *.git) ;;
  *) KSTACK_REPO="$KSTACK_REPO.git" ;;
esac
KSTACK_BRANCH=$(ask "${KSTACK_BRANCH:-}" "Branch ArgoCD tracks" main)
export KSTACK_REPO KSTACK_BRANCH

# Your fork, on your machine (a normal clone: you can edit and push from it later)
auth=()
if [ -n "${GIT_TOKEN:-}" ]; then
  auth=(-c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | base64 | tr -d '\n')")
fi
# ${auth[@]+...}: expands to nothing when auth is empty (bash 3.2 + set -u)
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" ${auth[@]+"${auth[@]}"} pull -q --ff-only origin "$KSTACK_BRANCH" \
    || die "cannot update $SRC (local changes?)"
else
  mkdir -p "$DIR"
  git ${auth[@]+"${auth[@]}"} clone -q -b "$KSTACK_BRANCH" "$KSTACK_REPO" "$SRC" \
    || die "cannot clone $KSTACK_REPO ($KSTACK_BRANCH)"
fi
if [ ! -f "$SRC/install.sh" ] || [ ! -f "$SRC/cluster.yaml" ]; then
  die "$KSTACK_REPO does not look like a kinopshq/core fork (no install.sh / cluster.yaml)"
fi
log "your fork: $SRC (edit, commit, push: ArgoCD applies it; rerun: cd $SRC && ./install.sh)"
exec bash "$SRC/install.sh" "$@"
