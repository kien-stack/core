#!/usr/bin/env bash
# kien/stack Essential bootstrap (free, Apache-2.0). Run it once, from YOUR fork, after editing it:
#   ./install.sh doctor      check the cluster and the repo
#   ./install.sh install     install ArgoCD + apply argocd/app-of-apps.yaml (default)
# Everything it uses is in Git, nothing is generated:
#   cluster.yaml             your settings (domain, TLS...), passed to every chart
#   argocd/app-of-apps.yaml  the repo/branch ArgoCD follows (same URL in argocd/applications/*/appset.yaml)
#   argocd/applications/platform/appset.yaml   bricks + namespace: comment out an entry to disable it
# After that, ArgoCD applies whatever you push. https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh does the edits for you.
# Optional environment variables (secrets, never stored in Git):
#   GIT_USERNAME / GIT_TOKEN          private GitOps repo (HTTPS)
#   DNS01_API_TOKEN                   if global.tls.issuer=letsencrypt-dns01
#   EXTERNAL_DNS_API_TOKEN            if the external-dns brick is enabled
# Output: one line per step, the full log in ./kstack-install.log.
#   --verbose / KSTACK_VERBOSE=1      raw logs on the terminal (old style), also written to the log file
#   KSTACK_LOG=<file>                 log file (default: kstack-install.log next to install.sh)
#   NO_COLOR=1 (or TERM=dumb, no TTY) plain text: no colors, no spinner; "- step ..." then "✔ step (1.2s)" / "✖ step"
#   KSTACK_UI_FAIL_STEP=<text>        debug: the step whose name contains <text> fails on purpose
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$ROOT/cluster.yaml"
APP="$ROOT/argocd/app-of-apps.yaml"
APPSET="$ROOT/argocd/applications/platform/appset.yaml"
PACK=essential
PACK_NAME=Essential
CMD=install
ARGOCD_TIMEOUT=${ARGOCD_TIMEOUT:-0}   # seconds to wait for the apps, 0 = until ready

# ---------------------------------------------------------------- ui (byte-identical in essential, ai, full)
# fancy: TTY, colors, Clack-style lines (◒ spinner, ◇ done, ■ failed, ▲ warning, │ bar). plain: no TTY /
# TERM=dumb / NO_COLOR, no ANSI, no \r, one line per event. verbose (--verbose, KSTACK_VERBOSE=1): the raw logs.
# Inside a step, stdout/stderr go to $UI_LOG in the old text format; warnings are also shown under the step.
UI_MODE=fancy UI_LOG=${KSTACK_LOG:-$ROOT/kstack-install.log} UI_LOGOK="" UI_STEP="" UI_SPIN="" UI_LINE="" UI_T0=$SECONDS
UI_STEP_T=0 UI_STEP_L=0 UI_HEAD="" UI_QUIET="" UI_COLS=80 UI_APPS=0
UI_WARNS=()
exec 7>&1 8>&2   # the terminal, whatever a step redirects
ui_setup() {
  local e=$'\033'
  if [ -n "${KSTACK_VERBOSE:-}" ] && [ "$KSTACK_VERBOSE" != 0 ]; then UI_MODE=verbose
  elif [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ] || [ -n "${NO_COLOR+x}" ]; then UI_MODE=plain
  else UI_MODE=fancy; fi
  if [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ] || [ -n "${NO_COLOR+x}" ]; then
    C_B="" C_D="" C_R="" C_G="" C_Y="" C_C="" C_BL="" C_GY="" C_0=""
  else C_B="${e}[1m" C_D="${e}[2m" C_R="${e}[31m" C_G="${e}[32m" C_Y="${e}[33m" C_C="${e}[36m" C_BL="${e}[1;34m" C_GY="${e}[90m" C_0="${e}[0m"; fi
  # old-style lines: colored on the terminal in verbose mode, plain text in the log file
  if [ "$UI_MODE" = verbose ]; then R_R=$C_R R_G=$C_G R_Y=$C_Y R_BL=$C_BL R_0=$C_0; else R_R="" R_G="" R_Y="" R_BL="" R_0=""; fi
}
ui_setup
ui_raw()   { [ "$UI_MODE" = verbose ] || [ -n "$UI_STEP" ]; }
ui_tolog() { [ -z "$UI_LOGOK" ] || printf '%s\n' "$*" >>"$UI_LOG"; }
# ui_fit <text> <room>: <text> cut to <room> characters (…), so that a line redrawn in place never wraps
ui_fit() {
  local t=$1 r=$2
  if [ "$r" -lt 1 ]; then return 0; fi
  if [ "${#t}" -gt "$r" ]; then t="${t:0:$(( r - 1 ))}…"; fi
  printf '%s' "$t"
}
# ui_line <color> <symbol> <text> [<text color>]: one Clack line on the terminal ("◇  text")
ui_line() { printf '%s%s%s  %s%s%s\n' "$1" "$2" "$C_0" "${4:-}" "$(ui_fit "$3" $(( UI_COLS - 3 )))" "$C_0" >&7; }
ui_bar()  { printf '%s│%s\n' "$C_GY" "$C_0" >&7; }
log()  {
  if ui_raw; then printf '%s[kien/stack]%s %s\n' "$R_BL" "$R_0" "$*"; return; fi
  ui_tolog "[kien/stack] $*"
  if [ "$UI_MODE" = fancy ]; then ui_line "$C_GY" '│' "$*"; else printf '%s\n' "$*" >&7; fi
}
ok()   {
  if ui_raw; then printf '  %sOK%s   %s\n' "$R_G" "$R_0" "$*"; return; fi
  ui_tolog "  OK   $*"
  if [ "$UI_MODE" = fancy ]; then ui_line "$C_G" '◇' "$*"; else printf '  ✔ %s\n' "$*" >&7; fi
}
warn() {
  if [ -n "$UI_STEP" ]; then UI_WARNS+=("$*"); fi
  if ui_raw; then printf '  %sWARN%s %s\n' "$R_Y" "$R_0" "$*"; return; fi
  ui_tolog "  WARN $*"
  if [ "$UI_MODE" = fancy ]; then ui_line "$C_Y" '▲' "$*" "$C_Y"; else printf '  ⚠ %s\n' "$*" >&7; fi
}
ko()   {
  if ui_raw; then printf '  %sKO%s   %s\n' "$R_R" "$R_0" "$*"; return; fi
  ui_tolog "  KO   $*"
  if [ "$UI_MODE" = fancy ]; then ui_line "$C_R" '■' "$*"; else printf '  ✖ %s\n' "$*" >&7; fi
}
die()  {
  if ui_raw; then printf '%s[kien/stack] ERROR:%s %s\n' "$R_R" "$R_0" "$*" >&2
  else
    ui_tolog "[kien/stack] ERROR: $*"
    if [ "$UI_MODE" = fancy ]; then printf '%s■  %s%s\n' "$C_R" "$*" "$C_0" >&8; else printf '✖ %s\n' "$*" >&8; fi
  fi
  exit 1
}
ui_now()  { if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s\n' "${EPOCHREALTIME/,/.}"; else date +%s; fi; }
ui_secs() { awk -v a="$1" -v b="$(ui_now)" 'BEGIN { printf "%.1f", b - a }'; }
ui_mmss() { if [ "$1" -lt 60 ]; then printf '%ds' "$1"; else printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); fi; }
ui_cols() {
  local c=""; c=$( { stty size </dev/tty; } 2>/dev/null || true); c=${c#* }
  case "$c" in ''|*[!0-9]*|0) c=${COLUMNS:-} ;; esac
  case "$c" in ''|*[!0-9]*|0) c=$(tput cols 2>/dev/null || true) ;; esac
  case "$c" in ''|*[!0-9]*|0) c=80 ;; esac; printf '%s\n' "$c"
}
ui_version() {
  local v=""
  [ ! -f "$ROOT/.release-please-manifest.json" ] || v=$(sed -n 's/.*"\.": *"\([^"]*\)".*/\1/p' "$ROOT/.release-please-manifest.json" | head -1)
  [ -n "$v" ] || [ ! -f "$ROOT/CHANGELOG.md" ] || v=$(awk '/^## /{ s=$2; sub(/^\[/, "", s); sub(/\].*/, "", s); sub(/^v/, "", s); print s; exit }' "$ROOT/CHANGELOG.md")
  printf '%s\n' "${v:-dev}"
}
# ui_init: after the arguments (--verbose). Truncates the log, prints the header, sets the traps.
ui_init() {
  ui_setup
  if { : >"$UI_LOG"; } 2>/dev/null; then UI_LOGOK=1
  else UI_LOG="${TMPDIR:-/tmp}/kstack-install.$$.log"; : >"$UI_LOG"; UI_LOGOK=1; fi
  local ver ctx; ver=$(ui_version); ctx=$(kubectl config current-context 2>/dev/null || true)
  UI_COLS=$(ui_cols)
  # shellcheck disable=SC2034  # UI_HEAD: read by the prompts block (no second ┌ header)
  if [ "$UI_MODE" = fancy ]; then
    ui_line "$C_GY" '┌' "kien/stack · ${PACK_NAME:-$PACK} v$ver"
    ui_line "$C_GY" '│' "Context: ${ctx:-none}   Log: $UI_LOG" "$C_D"; ui_bar; UI_HEAD=1
  else
    printf '%skien/stack %s%s %sv%s%s\n' "$C_B" "${PACK_NAME:-$PACK}" "$C_0" "$C_D" "$ver" "$C_0"
    printf '%sContext: %s   Log: %s%s\n\n' "$C_D" "${ctx:-none}" "$UI_LOG" "$C_0"
  fi
  printf 'kien/stack %s v%s, context %s, %s\n' "${PACK_NAME:-$PACK}" "$ver" "${ctx:-none}" "$(date)" >>"$UI_LOG"
  if [ "$UI_MODE" = verbose ]; then exec > >(tee -a "$UI_LOG") 2> >(tee -a "$UI_LOG" >&8); fi
  trap ui_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'UI_COLS=$(ui_cols)' WINCH
}
ui_exit() {
  local rc=$?
  ui_spin_stop
  if [ "$UI_MODE" = verbose ]; then return "$rc"; fi
  if [ -n "$UI_LINE" ]; then printf '\n' >&7; UI_LINE=""; fi
  if [ -n "$UI_STEP" ]; then ui_step_end "$rc"; fi
  if [ "$UI_MODE" = fancy ]; then printf '\033[?25h' >&7; fi
  UI_APPS=0
  if [ "$rc" -ne 0 ] && [ -z "$UI_QUIET" ]; then
    if [ "$UI_MODE" = fancy ]; then printf '%s└%s  %sLog: %s%s\n' "$C_GY" "$C_0" "$C_D" "$UI_LOG" "$C_0" >&8
    else printf 'Log: %s\n' "$UI_LOG" >&8; fi
  fi
  return "$rc"
}
ui_frame() { case $(( $1 % 4 )) in 0) printf '◒' ;; 1) printf '◐' ;; 2) printf '◓' ;; *) printf '◑' ;; esac; }
ui_spinner() {  # background: redraws "<frame>  <name> (<s>)" until killed
  local i=0 s=$SECONDS f name
  trap 'UI_COLS=$(ui_cols)' WINCH
  printf '\033[?25l'
  while :; do
    f=$(ui_frame "$i")
    name=$(ui_fit "$UI_STEP" $(( UI_COLS - 12 )))
    printf '\r%s%s%s  %s %s(%ds)%s\033[K' "$C_C" "$f" "$C_0" "$name" "$C_D" $(( SECONDS - s )) "$C_0"
    i=$(( i + 1 )); sleep 0.15
  done
}
ui_spin_stop() {
  if [ -z "$UI_SPIN" ]; then return 0; fi
  kill "$UI_SPIN" 2>/dev/null || true; wait "$UI_SPIN" 2>/dev/null || true; UI_SPIN=""
  printf '\r\033[K\033[?25h' >&7
}
ui_fake_fail() { echo "KSTACK_UI_FAIL_STEP=$KSTACK_UI_FAIL_STEP: simulated failure"; echo "doing things..."; echo "Error: fake error"; return 1; }
# step "<name>" cmd args...: runs cmd in this shell (variables it sets stay), output to $UI_LOG.
# Same exit behaviour as calling cmd directly (set -e applies as usual; the EXIT trap shows the failure).
step() {
  local name=$1; shift
  if [ -n "${KSTACK_UI_FAIL_STEP:-}" ]; then case "$name" in *"$KSTACK_UI_FAIL_STEP"*) set -- ui_fake_fail ;; esac; fi
  if [ "$UI_MODE" = verbose ]; then log "$name"; "$@"; return; fi
  UI_WARNS=(); UI_STEP_T=$(ui_now); UI_STEP_L=$(wc -l <"$UI_LOG"); UI_STEP=$name
  printf '\n== %s\n' "$name" >>"$UI_LOG"
  if [ "$UI_MODE" = fancy ]; then UI_COLS=$(ui_cols); ui_spinner >&7 2>/dev/null & UI_SPIN=$!
  else printf -- '- %s ...\n' "$name" >&7; fi
  "$@" >>"$UI_LOG" 2>&1
  local rc=$?
  ui_step_end "$rc"
  return "$rc"
}
ui_step_end() {
  local rc=$1 name=$UI_STEP t w
  ui_spin_stop; UI_STEP=""
  t=$(ui_secs "$UI_STEP_T")
  if [ "$UI_MODE" = fancy ]; then
    if [ "$rc" -eq 0 ]; then ui_line "$C_G" '◇' "$name ${C_D}(${t}s)"
    else ui_line "$C_R" '■' "$name ${C_D}(${t}s)" "$C_R"; fi
    for w in ${UI_WARNS[@]+"${UI_WARNS[@]}"}; do ui_line "$C_Y" '▲' "$w" "$C_Y"; done
  else
    if [ "$rc" -eq 0 ]; then printf '✔ %s (%ss)\n' "$name" "$t" >&7; else printf '✖ %s (%ss)\n' "$name" "$t" >&7; fi
    for w in ${UI_WARNS[@]+"${UI_WARNS[@]}"}; do printf '  ⚠ %s\n' "$w" >&7; done
  fi
  UI_WARNS=()
  if [ "$rc" -ne 0 ]; then
    tail -n +"$(( UI_STEP_L + 3 ))" "$UI_LOG" | tail -n 20 | while IFS= read -r w; do
      if [ "$UI_MODE" = fancy ]; then ui_line "$C_GY" '│' "$w" "$C_D"; else printf '    %s\n' "$w"; fi
    done >&7
  elif [ "$UI_MODE" = fancy ]; then ui_bar; fi
}
# ui_apps <frame#> <width> <name=status>...: the wait_apps lines (fancy), redrawn in place
ui_apps() {
  local w=$2 a st sym col tc out="" f
  f=$(ui_frame "$1"); shift 2
  for a in "$@"; do
    st=${a#*=} a=${a%%=*} tc=""
    case "$st" in
      OK)        sym='◇' col=$C_G ;;
      Degraded)  sym='▲' col=$C_Y tc=$C_Y ;;
      Timeout:*) sym='▲' col=$C_R tc=$C_R st=${st#Timeout:} ;;
      *)         sym=$f col=$C_C ;;
    esac
    a=$(printf '%-*s %s' "$w" "$a" "$st")
    out="$out${C_GY}│$C_0  $col$sym$C_0 $tc$(ui_fit "$a" $(( UI_COLS - 6 )))$C_0"$'\033[K\n'
  done
  if [ "$UI_APPS" -gt 0 ]; then printf '\033[%dA' "$UI_APPS" >&7; fi
  printf '\r%s' "$out" >&7; UI_APPS=$#
}
ui_done() {
  ui_tolog "Done in $(ui_mmss $(( SECONDS - UI_T0 )))"
  if [ "$UI_MODE" = fancy ]; then ui_line "$C_GY" '└' "Done in $(ui_mmss $(( SECONDS - UI_T0 )))" "$C_B$C_G"
  else printf '\nDone in %s\n' "$(ui_mmss $(( SECONDS - UI_T0 )))" >&7; fi
}
# ui_note <title> <line>...: a Clack note box (fancy), else the classic ┌─┐ box
ui_note() {
  local l w=0 bar t=$1; shift
  for l in "$t" "$@"; do [ "${#l}" -le "$w" ] || w=${#l}; done
  if [ "$UI_MODE" = fancy ]; then
    # printed once, never redrawn: no cut (the kubectl commands must stay complete)
    printf -v bar '%*s' $(( w - ${#t} + 1 )) ''; bar=${bar// /─}
    printf '%s◇%s  %s %s%s╮%s\n' "$C_G" "$C_0" "$t" "$C_GY" "$bar" "$C_0"
    printf -v bar '%*s' $(( w + 4 )) ''; printf '%s│%s│%s\n' "$C_GY" "$bar" "$C_0"
    for l in "$@"; do printf '%s│%s  %-*s  %s│%s\n' "$C_GY" "$C_0" "$w" "$l" "$C_GY" "$C_0"; done
    printf '%s│%s│%s\n' "$C_GY" "$bar" "$C_0"
    bar=${bar// /─}; printf '%s├%s╯%s\n' "$C_GY" "$bar" "$C_0"
  else
    printf -v bar '%*s' $((w + 2)) ''; bar=${bar// /─}
    printf '┌%s┐\n' "$bar"; printf '│ %-*s │\n' "$w" "$t"; printf '├%s┤\n' "$bar"
    for l in "$@"; do printf '│ %-*s │\n' "$w" "$l"; done
    printf '└%s┘\n' "$bar"
  fi
}
# ---------------------------------------------------------------- end ui

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    doctor|install) CMD=$1 ;;
    --pack) [ "${2:-}" = "$PACK" ] || die "this repo installs the $PACK pack"; shift ;;
    --verbose) KSTACK_VERBOSE=1 ;;
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

# Bricks ArgoCD will deploy: the entries of the platform ApplicationSet list, + helm/apps/*.
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

install_cilium() {
  log "Installing Cilium (CNI, before everything else; then managed by ArgoCD)"
  # LB pool / L2 policy CRDs only exist once the Cilium operator runs: ArgoCD adds them right after.
  helm_bootstrap cilium kube-system --set ciliumLB.enabled=false
  kubectl wait --for=condition=Ready nodes --all --timeout=5m >/dev/null
  ok "Cilium ready, nodes Ready"
}

install_argocd() {
  log "Installing ArgoCD (Helm, then self-managed by ArgoCD)"
  # The HTTPRoute needs the Gateway API CRDs, installed later by the traefik brick:
  # ArgoCD creates it when it takes itself over
  helm_bootstrap argocd argocd --set argo-cd.server.httproute.enabled=false
  ok "ArgoCD ready"
  ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
}

repo_credential() {
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
}

apply_app_of_apps() {
  log "kubectl apply -f argocd/app-of-apps.yaml (as committed in Git)"
  kubectl apply -f "$APP" >/dev/null
  ok "ArgoCD now syncs from $(repo) ($(rev)): push to change the platform"
}

install() {
  local comps; comps=$(enabled_components)
  log "Pack $PACK -> ArgoCD will deploy: $(tr '\n' ' ' <<<"$comps")"
  step "Prerequisites (doctor)" doctor || die "doctor failed: fix the prerequisites above"

  step "Bootstrap secrets" bootstrap_secrets "$comps"
  step "Internal DNS" internal_dns

  if grep -qx cilium <<<"$comps"; then step "Cilium" install_cilium; fi

  ARGOCD_PW=""
  step "ArgoCD (Helm install)" install_argocd
  log "ArgoCD login: admin / ${ARGOCD_PW:-<see argocd-initial-admin-secret>}"
  log "  UI now (no ingress needed): kubectl -n argocd port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"

  if [ -n "${GIT_TOKEN:-}" ]; then step "Git repo credential" repo_credential; fi

  step "App of apps" apply_app_of_apps

  wait_apps "$comps"
  ui_done
  summary
}

wait_apps() {
  # ArgoCD deploys every app in parallel; this shows each app's status until all are ready (no time limit by
  # default, ARGOCD_TIMEOUT=<seconds> to cap it). Ctrl+C is safe: ArgoCD keeps deploying.
  # Terminal: one line per app (◒ pending, ◇ OK, ▲ degraded), redrawn in place. Plain: one line per status
  # change per app. Verbose: the original table.
  if [ "$UI_MODE" = verbose ]; then wait_apps_table "$@"; return; fi
  local comps=$1 timeout=${ARGOCD_TIMEOUT%s} apps a n=0 w=12 start=$SECONDS
  apps="app-of-apps $comps"
  for a in $apps; do n=$((n + 1)); if [ ${#a} -ge $w ]; then w=$(( ${#a} + 2 )); fi; done
  ui_tolog "[kien/stack] Deploying $n apps with ArgoCD (Ctrl+C is safe: ArgoCD keeps going)"
  if [ "$UI_MODE" = fancy ]; then ui_line "$C_GY" '│' "Deploying $n apps with ArgoCD (Ctrl+C is safe: ArgoCD keeps going)" "$C_D"; printf '\033[?25l' >&7
  else printf 'Deploying %d apps with ArgoCD\n' "$n" >&7; fi
  UI_COLS=$(ui_cols); UI_APPS=0
  local rc=0 el=0 j i=0 st data ready row
  local -a last=() rows=()
  while :; do
    data=$'\n'$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
    el=$(( SECONDS - start )); ready=0; j=0; rows=()
    for a in $apps; do
      j=$((j + 1)); st=""
      if [[ "$data" == *$'\n'"$a="* ]]; then st=${data#*$'\n'"$a="}; st=${st%%$'\n'*}; fi
      case "$st" in
        Synced/Healthy) row=OK; ready=$((ready + 1)) ;;
        */Degraded)     row=Degraded ;;
        ""|/|*/)        row=Pending ;;
        */Healthy)      row=Syncing ;;
        *)              row=${st#*/} ;;
      esac
      if [ "${last[j]-unset}" != "$row" ]; then
        ui_tolog "  $a $row ($(ui_mmss "$el"))"
        if [ "$UI_MODE" = plain ]; then printf '  %-*s %s\n' "$w" "$a" "$row" >&7; fi
        last[j]=$row
      fi
      rows[${#rows[@]}]="$a=$row"
    done
    if [ "$ready" -eq "$n" ]; then break; fi
    if [ "${timeout:-0}" -gt 0 ] && [ "$el" -ge "$timeout" ]; then rc=1; break; fi
    if [ "$UI_MODE" = fancy ]; then
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
        ui_apps "$i" "$w" "${rows[@]}"; i=$((i + 1)); sleep 0.15
      done
    else sleep 2; fi
  done
  if [ "$UI_MODE" = fancy ]; then
    if [ "$rc" -ne 0 ]; then
      j=0; for a in "${rows[@]}"; do case "$a" in *=OK) ;; *) rows[j]="${a%%=*}=Timeout:${a#*=}" ;; esac; j=$((j + 1)); done
    fi
    ui_apps "$i" "$w" "${rows[@]}"; UI_APPS=0; printf '\033[?25h' >&7
  fi
  if [ "$rc" -eq 0 ]; then
    ui_tolog "  OK   all $n apps are ready ($(( el / 60 )) min $(( el % 60 )) s)"
    if [ "$UI_MODE" = fancy ]; then ui_line "$C_G" '◇' "$n/$n apps ready ${C_D}($(ui_mmss "$el"))"; ui_bar
    else printf '✔ %d/%d apps ready (%s)\n' "$n" "$n" "$(ui_mmss "$el")" >&7; fi
    return 0
  fi
  if [ "$UI_MODE" = fancy ]; then ui_line "$C_R" '■' "$ready/$n apps ready ${C_D}($(ui_mmss "$el"))" "$C_R"
  else printf '✖ %d/%d apps ready (%s)\n' "$ready" "$n" "$(ui_mmss "$el")" >&7; fi
  wait_apps_timeout
}

wait_apps_timeout() {
  warn "still not ready after ${ARGOCD_TIMEOUT%s}s (ArgoCD keeps deploying: kubectl -n argocd get applications)"
  if [ -z "$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)" ] \
     && [ "$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null)" = LoadBalancer ]; then
    warn "Traefik has no load balancer IP: minikube -> 'minikube tunnel'; homelab -> Cilium L2 (ciliumLB) or NodePort"
  fi
  return 1
}

wait_apps_table() {  # --verbose: the original per-app table
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
        Synced/Healthy) row=$'\033[32mOK\033[0m' ;;
        */Degraded)     row=$'\033[33mDegraded\033[0m'; pending=$((pending + 1)) ;;
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
  wait_apps_timeout
}

# access_box "<comps>" <domain>: URL / user / password of every enabled brick with a UI (charts in helm/).
# Passwords are never printed: only the kubectl command that reads them. Standalone: access_box "$(enabled_components)" my.domain
access_box() {
  local comps=$1 d=$2
  local -a L=("kien/stack access ($d)" "")
  sec() { printf "kubectl -n %s get secret %s -o jsonpath='{.data.%s}' | base64 -d" "$1" "$2" "$3"; }
  L+=("ArgoCD     https://argocd.$d" "  user      admin" "  password  $(sec argocd argocd-initial-admin-secret password)")
  if grep -qx infisical <<<"$comps"; then
    L+=("" "Infisical  https://infisical.$d" "  user      $(sec infisical infisical-admin email)" "  password  $(sec infisical infisical-admin password)")
  fi
  if grep -qx monitoring <<<"$comps"; then
    L+=("" "Grafana    https://grafana.$d" "  user      admin" "  password  $(sec monitoring grafana-admin admin-password)")
  fi
  if grep -qx hello <<<"$comps"; then L+=("" "hello      https://hello.$d" "  no login (sample nginx app)"); fi
  ui_note "${L[0]}" "${L[@]:2}"
}

summary() {
  local d out; d=$(cfg .global.domain)
  log "Done. Access:"
  out=$(UI_MODE=plain access_box "$(enabled_components)" "$d")
  printf '%s\n' "$out" >"$ROOT/kstack-access.txt"
  if [ "$UI_MODE" = fancy ]; then access_box "$(enabled_components)" "$d"; else printf '%s\n' "$out"; fi
  echo "  (saved to $ROOT/kstack-access.txt, no password inside)"
  echo "  Change anything: edit cluster.yaml or helm/*/<brick>/values.yaml in $(repo), push."
  [ "$(cfg .global.tls.issuer)" = selfsigned ] && echo "  (self-signed certificates: CA in cert-manager/selfsigned-ca)"
  return 0
}

command -v yq >/dev/null 2>&1 || die "yq (mikefarah, v4) is required"
ui_init
case "$CMD" in
  doctor) doctor ;;
  install) install ;;
esac
