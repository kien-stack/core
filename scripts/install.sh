#!/usr/bin/env bash
# kinops Community INSTALL: the real, free install on your cluster.
#   curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash -s uninstall
# Before: fork https://github.com/kinopshq/core (you need push access to your fork).
# Clones YOUR fork, then runs its ./install.sh (questions on first run, commit + push, install).
# Same as: git clone <your fork> && cd <it> && ./install.sh
# Non-interactive: KSTACK_REPO, KSTACK_BRANCH, KSTACK_DOMAIN, KSTACK_EMAIL, KSTACK_IP, KSTACK_CILIUM,
# KSTACK_YES=1; GIT_USERNAME/GIT_TOKEN for a private repo. Requires kubectl, helm, git.
set -euo pipefail
UPSTREAM=https://github.com/kinopshq/core
DIR=${KSTACK_DIR:-$HOME/kien-stack}
# colors: only on a TTY, honour NO_COLOR and TERM=dumb (bash 3.2 safe)
kc() { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
# shellcheck disable=SC2034
if kc 1; then C_H=$'\033[1;36m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_D=$'\033[2m' C_0=$'\033[0m'; else C_H='' C_G='' C_Y='' C_R='' C_D='' C_0=''; fi
if kc 2; then E_R=$'\033[1;31m' E_0=$'\033[0m'; else E_R='' E_0=''; fi
log() { printf '%s[kinops]%s %s\n' "${C_H}" "${C_0}" "$*"; }
die() { printf '%serror:%s %s\n' "${E_R}" "${E_0}" "$*" >&2; exit 1; }
ask() { # ask VAR "question" default
  local v=${!1:-}; if [ -n "$v" ] || [ -n "${KSTACK_YES:-}" ] || ! { : </dev/tty; } 2>/dev/null; then printf -v "$1" %s "${v:-$3}"; return; fi
  read -r -p "  $2 [${3:-none}]: " v </dev/tty || true; printf -v "$1" %s "${v:-$3}"
}

for b in kubectl helm git; do command -v "$b" >/dev/null || die "$b is required (https://helm.sh/docs/intro/install, https://kubernetes.io/docs/tasks/tools)"; done
if ! command -v yq >/dev/null; then
  mkdir -p "$DIR/.bin"; export PATH="$DIR/.bin:$PATH"
  if ! [ -x "$DIR/.bin/yq" ]; then
    os=$(uname -s | tr A-Z a-z); arch=$(uname -m); case $arch in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
    log "fetching yq ($os/$arch)"; curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${arch}" -o "$DIR/.bin/yq"; chmod +x "$DIR/.bin/yq"
  fi
fi
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "no reachable cluster in the current kubectl context.
  No Kubernetes? k3s in one minute: curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"--disable traefik\" sh -"

SRC="$DIR/repo"
if [ "${1:-}" = uninstall ]; then
  # uninstall only needs the script: your clone if any, else ours
  if [ ! -f "$SRC/install.sh" ]; then
    SRC=$(mktemp -d); git clone -q --depth 1 "${KSTACK_SOURCE:-$UPSTREAM}" "$SRC"
  fi
  exec bash "$SRC/install.sh" "$@"
fi

ask KSTACK_REPO "Your fork of kinopshq/core, HTTPS URL" ""
[ -n "$KSTACK_REPO" ] || die "a GitOps repo is required: fork $UPSTREAM first (or run https://raw.githubusercontent.com/kinopshq/core/main/scripts/try.sh for a demo)"
case "$KSTACK_REPO" in *kinopshq/core*|*kien-stack/core*|*kien-stack/essential*|*dedsxc/kien-stack-essential*) die "that is our public repo: use your fork (or try.sh for a demo)" ;; esac
case "$KSTACK_REPO" in *.git) ;; *) KSTACK_REPO="$KSTACK_REPO.git" ;; esac
ask KSTACK_BRANCH "Branch ArgoCD tracks" main
export KSTACK_REPO KSTACK_BRANCH

# Your fork, on your machine (a normal clone: you can edit and push from it later)
auth=()
[ -z "${GIT_TOKEN:-}" ] || auth=(-c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | base64 | tr -d '\n')")
if [ -d "$SRC/.git" ]; then git -C "$SRC" ${auth[@]+"${auth[@]}"} pull -q --ff-only origin "$KSTACK_BRANCH" || die "cannot update $SRC (local changes?)"
else mkdir -p "$DIR"; git ${auth[@]+"${auth[@]}"} clone -q -b "$KSTACK_BRANCH" "$KSTACK_REPO" "$SRC" || die "cannot clone $KSTACK_REPO ($KSTACK_BRANCH)"; fi
[ -f "$SRC/install.sh" ] && [ -f "$SRC/cluster.yaml" ] || die "$KSTACK_REPO does not look like a kinopshq/core fork (no install.sh / cluster.yaml)"
log "your fork: $SRC (edit, commit, push: ArgoCD applies it; rerun: cd $SRC && ./install.sh)"
exec bash "$SRC/install.sh" "$@"
