#!/usr/bin/env bash
# kien/stack Essential INSTALL: the real, free install on your cluster.
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash -s uninstall
# Before: fork https://github.com/kien-stack/essential (you need push access to your fork).
# What it does, all visible in your Git history:
#   1. clones YOUR fork, asks a few questions
#   2. writes the answers into cluster.yaml and argocd/*.yaml, shows the diff, commits, pushes
#   3. runs ./install.sh from your fork: secrets, ArgoCD, kubectl apply argocd/app-of-apps.yaml
# Then ArgoCD applies whatever you push. Change a setting later: edit cluster.yaml, push.
# Questions: Clack-style menus on /dev/tty (arrows + Enter); KSTACK_PROMPT_PLAIN=1 (or NO_COLOR) for plain
# numbered prompts. Nothing is written before the summary's "Proceed?".
# Non-interactive: KSTACK_REPO, KSTACK_BRANCH, KSTACK_DOMAIN (skips the domain menu), KSTACK_EMAIL, KSTACK_IP,
# KSTACK_CILIUM=true|false, KSTACK_YES=1; GIT_USERNAME/GIT_TOKEN for a private repo. Output: --verbose / KSTACK_VERBOSE=1, KSTACK_LOG, NO_COLOR. Requires kubectl, helm, git.
set -euo pipefail
UPSTREAM=https://github.com/kien-stack/essential
DIR=${KSTACK_DIR:-$HOME/kien-stack}
# Colors only on a terminal without NO_COLOR/TERM=dumb. --verbose or KSTACK_VERBOSE=1: raw logs from ./install.sh.
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then C_M=$'\033[1;35m' C_R=$'\033[31m' C_0=$'\033[0m'; else C_M="" C_R="" C_0=""; fi
log() { if [ -n "${P_FANCY:-}" ] && [ -n "${P_ON:-}" ]; then p_log "$*"; else printf '%s[kien/stack]%s %s\n' "$C_M" "$C_0" "$*"; fi; }
die() { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
ARG=""
for a in "$@"; do case "$a" in --verbose) export KSTACK_VERBOSE=1 ;; *) ARG=${ARG:-$a} ;; esac; done
set -- ${ARG:+"$ARG"}
# ---- prompts (byte-identical in essential, ai, full)
# Clack-style questions (the @clack/prompts look) in pure bash 3.2+, no dependency. They read and write
# /dev/tty, so `curl ... | bash` works. No question (value = env or default, as before) when the variable is
# already set, KSTACK_YES is set or /dev/tty cannot be opened.
# KSTACK_PROMPT_PLAIN=1 (also NO_COLOR, TERM=dumb): plain prompts, "? Question (default): ", numbered menus, no ANSI.
# Use: p_intro, p_text VAR "Question" default [validator], p_secret, p_confirm VAR "Question" Y|N (true/false),
# p_select VAR "Question" default_index "label|value"..., p_multiselect VAR "Question" "label|value|on"...
# (space-separated values), p_summary "Label|value"... (then Proceed?), p_outro "text", p_end.
P_INIT="" P_ON="" P_FANCY="" P_STTY="" P_TRAPS="" P_PREV=0 P_COLS=80 P_ROWS=24 P_T="" P_ST="" P_Q="" P_V=""
P_DEF="" P_ERR="" P_ANS="" P_I=0 P_K="" P_C="" P_BUF="" P_NL=0 P_RAW=""
P_OL=() P_OV=() P_OS=()
P_CY="" P_GR="" P_YE="" P_RE="" P_DI="" P_GY="" P_IN="" P_0=""
p_init() {
  if [ -n "$P_INIT" ]; then return 0; fi
  P_INIT=1
  if [ -n "${KSTACK_YES:-}" ] || ! { : <>/dev/tty; } 2>/dev/null; then return 0; fi
  exec 6<>/dev/tty; P_ON=1
  if [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ] && [ "${KSTACK_PROMPT_PLAIN:-}" != 1 ]; then
    P_FANCY=1 P_CY=$'\033[36m' P_GR=$'\033[32m' P_YE=$'\033[33m' P_RE=$'\033[31m' P_DI=$'\033[2m' P_GY=$'\033[90m'
    P_IN=$'\033[7m' P_0=$'\033[0m'
  fi
  P_STTY=$(stty -g <&6 2>/dev/null || true)
  P_TRAPS="$(trap -p INT; trap -p TERM; trap -p WINCH)"
  trap p__cancel INT TERM
  trap p__winch WINCH
  p__size
}
p_end() {  # restore the traps, the terminal and the cursor
  if [ -z "$P_ON" ]; then return 0; fi
  p__cooked; trap - INT TERM WINCH; eval "$P_TRAPS"; P_ON=""
}
p__size() {
  local s r c; s=$(stty size <&6 2>/dev/null || true); r=${s% *} c=${s#* }
  case "$c" in ''|*[!0-9]*|0) c=$(tput cols 2>/dev/null || true) ;; esac
  case "$c" in ''|*[!0-9]*|0) c=80 ;; esac
  case "$r" in ''|*[!0-9]*|0) r=24 ;; esac
  P_COLS=$c P_ROWS=$r
}
p__raw() {
  if [ -n "$P_FANCY" ]; then stty -echo -icanon <&6 2>/dev/null || true; printf '\033[?25l' >&6; P_RAW=1; fi
}
p__cooked() {
  if [ -n "$P_RAW" ]; then
    if [ -n "$P_STTY" ]; then stty "$P_STTY" <&6 2>/dev/null || stty sane <&6 2>/dev/null || true; fi
    printf '\033[?25h' >&6; P_RAW=""
  fi
}
p__winch() {  # terminal resized: new width, redraw the question in full below
  p__size
  if [ -n "$P_RAW" ]; then case "$P_ST" in active|error) P_PREV=0; p__render ;; esac; fi
}
# shellcheck disable=SC2034  # UI_QUIET: read by the ui EXIT trap of install.sh
p__cancel() {
  if [ -n "$P_FANCY" ]; then
    case "$P_ST" in active|error) P_ANS=""; if [ "$P_T" = text ]; then P_ANS=$P_V; fi; P_ST=cancel; p__render ;; esac
    printf '%s└%s  %sOperation cancelled.%s\n' "$P_GY" "$P_0" "$P_RE" "$P_0" >&6
  else printf '\nCancelled.\n' >&6; fi
  P_RAW=1; p__cooked; trap - INT TERM WINCH; UI_QUIET=1; exit 130
}
p__ver() {  # p__ver <dir>: "v1.2.3" from the release manifest, CHANGELOG, version file or git, else nothing
  local d=$1 v=""
  if [ -z "$d" ] || [ ! -d "$d" ]; then return 0; fi
  [ ! -f "$d/.release-please-manifest.json" ] || v=$(sed -n 's/.*"\.": *"\([^"]*\)".*/\1/p' "$d/.release-please-manifest.json" | head -1)
  [ -n "$v" ] || [ ! -f "$d/CHANGELOG.md" ] || v=$(awk '/^## /{ s=$2; sub(/^\[/, "", s); sub(/\].*/, "", s); print s; exit }' "$d/CHANGELOG.md")
  [ -n "$v" ] || [ ! -f "$d/version" ] || v=$(head -1 "$d/version")
  [ -n "$v" ] || v=$(git -C "$d" describe --tags --abbrev=0 2>/dev/null || true)
  if [ -n "$v" ]; then printf 'v%s\n' "${v#v}"; fi
}
p_intro() {  # p_intro <Pack name> [<repo dir for the version>]
  p_init; if [ -z "$P_ON" ]; then return 0; fi
  local v; v=$(p__ver "${2:-}")
  P_BUF="" P_NL=0
  if [ -n "$P_FANCY" ]; then
    if [ -z "${UI_HEAD:-}" ]; then p__ln "${P_GY}┌" "" 0 "kien/stack · $1${v:+ $v}" ""; printf '%s' "$P_BUF" >&6; fi
    p__ln "${P_GY}│" "" 0 "Answer a few questions. Enter keeps the default." "$P_DI"; p__ln "${P_GY}│" "" 0 "" ""
    printf '%s' "$P_BUF" >&6
  else printf 'kien/stack - %s%s\nAnswer a few questions. Enter keeps the default.\n\n' "$1" "${v:+ $v}" >&6; fi
}
p_outro() {  # p_outro <text>: last line of the questions, then p_end
  if [ -n "$P_ON" ]; then
    P_BUF="" P_NL=0
    if [ -n "$P_FANCY" ]; then p__ln "${P_GY}└" "" 0 "$1" ""; printf '%s' "$P_BUF" >&6; else printf '%s\n' "$1" >&6; fi
  fi
  p_end
}
p_log() {  # p_log <line>...: plain lines inside the questions (diffs...), on stdout
  local l
  for l in "$@"; do if [ -n "$P_FANCY" ]; then printf '%s│%s  %s\n' "$P_GY" "$P_0" "$l"; else printf '  %s\n' "$l"; fi; done
}
# p__ln <colored symbol> <colored mark> <mark width> <text> <text color> [<colored 1-char suffix>]: append
# one line to P_BUF, cut to the terminal width so that a redraw never wraps.
p__ln() {
  local t=$4 room=$(( P_COLS - 4 - $3 ))
  if [ -n "${6:-}" ]; then room=$(( room - 1 )); fi
  if [ "$room" -lt 1 ]; then t=""; elif [ "${#t}" -gt "$room" ]; then t="${t:0:$(( room - 1 ))}…"; fi
  P_BUF="$P_BUF$1$P_0  $2$5$t$P_0${6:-}"$'\033[K\n'; P_NL=$(( P_NL + 1 ))
}
p__render() {
  local s sc bc i first last m t
  P_BUF="" P_NL=0
  case "$P_ST" in
    error)  s='▲' sc=$P_YE bc=$P_YE ;;
    ok)     s='◇' sc=$P_GR bc=$P_GY ;;
    cancel) s='■' sc=$P_RE bc=$P_GY ;;
    *)      s='◆' sc=$P_CY bc=$P_CY ;;
  esac
  p__ln "$sc$s" "" 0 "$P_Q" ""
  if [ "$P_ST" = ok ] || [ "$P_ST" = cancel ]; then
    p__ln "${bc}│" "" 0 "$P_ANS" "$P_DI"
    if [ "$P_ST" = ok ]; then p__ln "${bc}│" "" 0 "" ""; fi
  else
    case "$P_T" in
      text|secret)
        t=$P_V; if [ "$P_T" = secret ]; then t=$(printf '%*s' "${#P_V}" '' | tr ' ' '*'); fi
        m=$(( P_COLS - 6 ))
        if [ "$m" -lt 2 ]; then t=""; elif [ "${#t}" -gt "$m" ]; then t="…${t:$(( ${#t} - m + 1 ))}"; fi
        if [ -z "$t" ] && [ -n "$P_DEF" ]; then p__ln "${bc}│" "$P_IN${P_DEF:0:1}$P_0" 1 "${P_DEF:1}" "$P_DI"
        else p__ln "${bc}│" "" 0 "$t" "" "$P_IN $P_0"; fi ;;
      confirm)
        if [ "$P_I" = 0 ]; then p__ln "${bc}│" "" 0 "${P_GR}●$P_0 Yes $P_DI/ ○ No" ""
        else p__ln "${bc}│" "" 0 "${P_DI}○ Yes /$P_0 ${P_GR}●$P_0 No" ""; fi ;;
      *)
        m=$(( P_ROWS - 5 )); if [ "$m" -lt 3 ]; then m=3; fi
        first=0 last=$(( ${#P_OL[@]} - 1 ))
        if [ "${#P_OL[@]}" -gt "$m" ]; then
          first=$(( P_I - m / 2 )); if [ "$first" -lt 0 ]; then first=0; fi
          if [ $(( first + m - 1 )) -gt "$last" ]; then first=$(( last - m + 1 )); fi
          last=$(( first + m - 1 ))
        fi
        if [ "$first" -gt 0 ]; then p__ln "${bc}│" "" 0 "…" "$P_DI"; fi
        i=$first
        while [ "$i" -le "$last" ]; do
          if [ "$P_T" = select ]; then
            if [ "$i" = "$P_I" ]; then p__ln "${bc}│" "${P_GR}●$P_0 " 2 "${P_OL[i]}" ""
            else p__ln "${bc}│" "${P_DI}○$P_0 " 2 "${P_OL[i]}" "$P_DI"; fi
          else
            if [ "${P_OS[i]}" = 1 ]; then t="${P_GR}◼$P_0 "; elif [ "$i" = "$P_I" ]; then t="${P_CY}◻$P_0 "; else t="${P_DI}◻$P_0 "; fi
            if [ "$i" = "$P_I" ]; then p__ln "${bc}│" "$t" 2 "${P_OL[i]}" ""; else p__ln "${bc}│" "$t" 2 "${P_OL[i]}" "$P_DI"; fi
          fi
          i=$(( i + 1 ))
        done
        if [ "$last" -lt $(( ${#P_OL[@]} - 1 )) ]; then p__ln "${bc}│" "" 0 "…" "$P_DI"; fi
        if [ "$P_T" = multi ] && [ "$P_ST" != error ]; then p__ln "${bc}│" "" 0 "space: toggle, a: all, enter: confirm" "$P_DI"; fi ;;
    esac
    if [ "$P_ST" = error ]; then p__ln "${P_YE}└" "" 0 "▲  $P_ERR" "$P_YE"; else p__ln "${bc}└" "" 0 "" ""; fi
  fi
  if [ "$P_PREV" -gt 0 ]; then printf '\033[%dA' "$P_PREV" >&6; fi
  printf '\r\033[J%s' "$P_BUF" >&6
  case "$P_ST" in ok|cancel) P_PREV=0 ;; *) P_PREV=$P_NL ;; esac
}
p__key() {  # one key from the terminal -> P_K (up down left right enter space bs esc char eof), P_C
  local c="" r=""
  P_K="" P_C=""
  if ! IFS= read -rsn1 c <&6; then P_K=eof; return 0; fi
  case "$c" in
    "")       P_K=enter ;;
    $'\r')    P_K=enter ;;
    ' ')      P_K=space ;;
    $'\177'|$'\b') P_K=bs ;;
    $'\033')  IFS= read -rsn2 -t 1 r <&6 || true
              case "$r" in '[A'|OA) P_K=up ;; '[B'|OB) P_K=down ;; '[C'|OC) P_K=right ;; '[D'|OD) P_K=left ;; *) P_K=esc ;; esac ;;
    *)        P_K=char P_C=$c ;;
  esac
}
p__skip() {  # p__skip VAR default: no question (env value or default)? sets VAR then
  p_init
  if [ -n "${!1:-}" ]; then return 0; fi
  if [ -z "$P_ON" ]; then printf -v "$1" %s "$2"; return 0; fi
  return 1
}
p__input() {  # p__input VAR question default validator text|secret
  local v err=""
  P_T=$5 P_Q=$2 P_DEF=$3 P_V="" P_ST=active P_ERR="" P_PREV=0
  if [ -z "$P_FANCY" ]; then
    while :; do
      printf '? %s%s: ' "$2" "${3:+ ($3)}" >&6; v=""
      if [ "$5" = secret ]; then IFS= read -rs v <&6 || true; printf '\n' >&6; else IFS= read -r v <&6 || true; fi
      v=${v:-$3}
      if [ -n "$4" ] && ! err=$("$4" "$v"); then printf '  ! %s\n' "$err" >&6; continue; fi
      break
    done
  else
    p__raw; p__render
    while :; do
      p__key
      case "$P_K" in
        eof) p__cancel ;;
        enter)
          v=${P_V:-$3}
          if [ -n "$4" ] && ! err=$("$4" "$v"); then P_ST=error P_ERR=$err; p__render; continue; fi
          break ;;
        bs) P_V=${P_V%?} ;;
        space) P_V="$P_V " ;;
        char) P_V="$P_V$P_C" ;;
        *) continue ;;
      esac
      P_ST=active; p__render
    done
    P_ANS=${v:-(none)}; if [ "$5" = secret ]; then P_ANS=$(printf '%*s' "${#v}" '' | tr ' ' '*'); fi
    P_ST=ok; p__render; p__cooked
  fi
  P_T="" P_ST=""; printf -v "$1" %s "$v"
}
p_text()   { if p__skip "$1" "$3"; then return 0; fi; p__input "$1" "$2" "$3" "${4:-}" text; }
p_secret() { if p__skip "$1" "$3"; then return 0; fi; p__input "$1" "$2" "$3" "${4:-}" secret; }
p_confirm() {  # p_confirm VAR "Question" Y|N: VAR=true|false
  local d=false v; if [ "$3" = Y ] || [ "$3" = y ]; then d=true; fi
  if p__skip "$1" "$d"; then return 0; fi
  P_T=confirm P_Q=$2 P_ST=active P_PREV=0 P_I=1; if [ "$d" = true ]; then P_I=0; fi
  if [ -z "$P_FANCY" ]; then
    while :; do
      if [ "$d" = true ]; then printf '? %s (Y/n): ' "$2" >&6; else printf '? %s (y/N): ' "$2" >&6; fi
      v=""; IFS= read -r v <&6 || true
      case "$v" in
        "") v=$d ;;
        [yY]|[yY][eE][sS]) v=true ;;
        [nN]|[nN][oO]) v=false ;;
        *) printf '  ! answer y or n\n' >&6; continue ;;
      esac
      break
    done
  else
    p__raw; p__render
    while :; do
      p__key
      case "$P_K" in
        eof) p__cancel ;;
        enter) break ;;
        up|down|left|right) P_I=$(( 1 - P_I )) ;;
        char) case "$P_C" in [yY]) P_I=0 ;; [nN]) P_I=1 ;; [hjklHJKL]) P_I=$(( 1 - P_I )) ;; *) continue ;; esac ;;
        *) continue ;;
      esac
      p__render
    done
    v=false P_ANS=No; if [ "$P_I" = 0 ]; then v=true P_ANS=Yes; fi
    P_ST=ok; p__render; p__cooked
  fi
  P_T="" P_ST=""; printf -v "$1" %s "$v"
}
p__opts() {  # "label|value[|on]"... -> P_OL P_OV P_OS
  local o; P_OL=() P_OV=() P_OS=()
  for o in "$@"; do
    P_OL[${#P_OL[@]}]=${o%%|*}; o=${o#*|}
    P_OV[${#P_OV[@]}]=${o%%|*}
    case "$o" in *'|on') P_OS[${#P_OS[@]}]=1 ;; *) P_OS[${#P_OS[@]}]=0 ;; esac
  done
}
p_select() {  # p_select VAR "Question" default_index(1-based) "label|value"...
  local var=$1 q=$2 d=$3 n v i; shift 3; p__opts "$@"; n=${#P_OL[@]}
  if [ "$d" -lt 1 ] || [ "$d" -gt "$n" ]; then d=1; fi
  if p__skip "$var" "${P_OV[d - 1]}"; then return 0; fi
  P_T=select P_Q=$q P_ST=active P_PREV=0 P_I=$(( d - 1 ))
  if [ -z "$P_FANCY" ]; then
    printf '? %s\n' "$q" >&6; i=0
    while [ "$i" -lt "$n" ]; do printf '  %d) %s\n' $(( i + 1 )) "${P_OL[i]}" >&6; i=$(( i + 1 )); done
    while :; do
      printf 'Choice (%d): ' "$d" >&6; v=""; IFS= read -r v <&6 || true; v=${v:-$d}
      case "$v" in ''|*[!0-9]*) ;; *) if [ "$v" -ge 1 ] && [ "$v" -le "$n" ]; then break; fi ;; esac
      printf '  ! enter a number from 1 to %d\n' "$n" >&6
    done
    P_I=$(( v - 1 ))
  else
    p__raw; p__render
    while :; do
      p__key
      case "$P_K" in
        eof) p__cancel ;;
        enter) break ;;
        up|left) P_I=$(( (P_I + n - 1) % n )) ;;
        down|right) P_I=$(( (P_I + 1) % n )) ;;
        char) case "$P_C" in k|h) P_I=$(( (P_I + n - 1) % n )) ;; j|l) P_I=$(( (P_I + 1) % n )) ;; *) continue ;; esac ;;
        *) continue ;;
      esac
      p__render
    done
    P_ANS=${P_OL[P_I]} P_ST=ok; p__render; p__cooked
  fi
  P_T="" P_ST=""; printf -v "$var" %s "${P_OV[P_I]}"
}
p__picked() {  # P_OS -> P_V (values) and P_ANS (labels)
  local i=0; P_V="" P_ANS=""
  while [ "$i" -lt "${#P_OL[@]}" ]; do
    if [ "${P_OS[i]}" = 1 ]; then P_V="$P_V${P_V:+ }${P_OV[i]}" P_ANS="$P_ANS${P_ANS:+, }${P_OL[i]}"; fi
    i=$(( i + 1 ))
  done
  P_ANS=${P_ANS:-(none)}
}
p_multiselect() {  # p_multiselect VAR "Question" "label|value|on"...: VAR="value value..."
  local var=$1 q=$2 n v i all; shift 2; p__opts "$@"; n=${#P_OL[@]}
  p__picked; if p__skip "$var" "$P_V"; then return 0; fi
  P_T=multi P_Q=$q P_ST=active P_PREV=0 P_I=0
  if [ -z "$P_FANCY" ]; then
    printf '? %s\n' "$q" >&6; i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${P_OS[i]}" = 1 ]; then v=x; else v=" "; fi
      printf '  %d) [%s] %s\n' $(( i + 1 )) "$v" "${P_OL[i]}" >&6; i=$(( i + 1 ))
    done
    while :; do
      printf 'Numbers, comma-separated (empty = the [x] ones): ' >&6; v=""; IFS= read -r v <&6 || true
      if [ -z "$v" ]; then break; fi
      all=$(printf '%s' "$v" | tr ',' ' ' | grep -v '^$' || true); v=ok
      for i in $all; do case "$i" in *[!0-9]*) v="" ;; *) if [ "$i" -lt 1 ] || [ "$i" -gt "$n" ]; then v=""; fi ;; esac; done
      if [ -n "$v" ] && [ -n "$all" ]; then
        i=0; while [ "$i" -lt "$n" ]; do P_OS[i]=0; i=$(( i + 1 )); done
        for i in $all; do P_OS[i - 1]=1; done; break
      fi
      printf '  ! numbers from 1 to %d, e.g. 1,3\n' "$n" >&6
    done
    p__picked
  else
    p__raw; p__render
    while :; do
      p__key
      case "$P_K" in
        eof) p__cancel ;;
        enter) break ;;
        up|left) P_I=$(( (P_I + n - 1) % n )) ;;
        down|right) P_I=$(( (P_I + 1) % n )) ;;
        space) P_OS[P_I]=$(( 1 - P_OS[P_I] )) ;;
        char)
          case "$P_C" in
            k|h) P_I=$(( (P_I + n - 1) % n )) ;;
            j|l) P_I=$(( (P_I + 1) % n )) ;;
            a) all=1; i=0; while [ "$i" -lt "$n" ]; do if [ "${P_OS[i]}" = 0 ]; then all=0; fi; i=$(( i + 1 )); done
               i=0; while [ "$i" -lt "$n" ]; do P_OS[i]=$(( 1 - all )); i=$(( i + 1 )); done ;;
            *) continue ;;
          esac ;;
        *) continue ;;
      esac
      p__render
    done
    p__picked; P_ST=ok; p__render; p__cooked
  fi
  P_T="" P_ST=""; printf -v "$var" %s "$P_V"
}
p__pad() { local s=$1; while [ "${#s}" -lt "$2" ]; do s="$s "; done; printf '%s' "$s"; }
p_summary() {  # p_summary "Label|value"...: note box, then "Proceed?" (Yes). Returns 1 on No.
  p_init; if [ -z "$P_ON" ]; then return 0; fi
  local o l lw=0 w=12 room h v b tl tr bl br hz vt line ok
  for o in "$@"; do l=${o%%|*}; if [ "${#l}" -gt "$lw" ]; then lw=${#l}; fi; done
  room=$(( P_COLS - 7 ))
  for o in "$@"; do v=${o#*|}; l=$(( lw + 2 + ${#v} )); if [ "$l" -gt "$w" ]; then w=$l; fi; done
  if [ "$w" -gt "$room" ]; then w=$room; fi
  if [ "$w" -lt 8 ]; then w=8; fi
  if [ -n "$P_FANCY" ]; then tl='◇' tr='╮' bl='├' br='╯' hz='─' vt='│'; else tl='+' tr='+' bl='+' br='+' hz='-' vt='|'; fi
  h=""; while [ "${#h}" -lt $(( w - 6 )) ]; do h="$h$hz"; done
  b=""; while [ "${#b}" -lt $(( w + 4 )) ]; do b="$b$hz"; done
  {
    if [ -n "$P_FANCY" ]; then printf '%s%s%s  Summary %s%s%s\n' "$P_GR" "$tl" "$P_0" "$P_GY" "$h$tr" "$P_0"
    else printf '%s  Summary %s%s\n' "$tl" "$h" "$tr"; fi
    printf '%s%s  %s  %s%s\n' "$P_GY" "$vt" "$(p__pad "" "$w")" "$vt" "$P_0"
    for o in "$@"; do
      l=$(p__pad "${o%%|*}" "$lw") v=${o#*|}
      if [ $(( lw + 2 + ${#v} )) -gt "$w" ]; then v="${v:0:$(( w - lw - 3 ))}…"; fi
      line=$(p__pad "$l  $v" "$w")
      printf '%s%s%s  %s%s%s  %s%s%s\n' "$P_GY" "$vt" "$P_0" "${line:0:$lw}" "$P_DI" "${line:$lw}" "$P_GY" "$vt" "$P_0"
    done
    printf '%s%s  %s  %s%s\n' "$P_GY" "$vt" "$(p__pad "" "$w")" "$vt" "$P_0"
    printf '%s%s%s%s%s\n' "$P_GY" "$bl" "$b" "$br" "$P_0"
  } >&6
  p_confirm ok "Proceed?" Y
  [ "$ok" = true ]
}
# Validators: print a message and fail when the value is not valid.
v_url() {
  case "$1" in
    https://*/*) case "$1" in *' '*|https:///*) ;; *) return 0 ;; esac ;;
  esac
  echo "must be an HTTPS git URL, e.g. https://github.com/you/kien-stack-essential"; return 1
}
v_email() {
  case "$1" in
    *' '*|*@*@*|@*|*@|*@.*|*.) ;;
    ?*@?*.?*) return 0 ;;
  esac
  echo "must be an email address, e.g. you@example.com"; return 1
}
v_email_opt() { if [ -z "$1" ]; then return 0; fi; v_email "$1"; }
v_ip() {
  local o n=0 IFS=.
  case "$1" in ''|*[!0-9.]*|.*|*.|*..*) echo "must be an IPv4 address, e.g. 192.168.1.10"; return 1 ;; esac
  for o in $1; do
    n=$(( n + 1 ))
    if [ "${#o}" -gt 3 ] || [ "$o" -gt 255 ]; then echo "must be an IPv4 address (four numbers 0-255)"; return 1; fi
  done
  if [ "$n" -ne 4 ]; then echo "must be an IPv4 address (four numbers 0-255)"; return 1; fi
}
v_domain() {
  case "$1" in
    *.*) case "$1" in *[!abcdefghijklmnopqrstuvwxyz0123456789.-]*|.*|*.|*..*|-*|*-|*.-*|*-.*) ;; *) return 0 ;; esac ;;
  esac
  echo "must be a domain like apps.example.com (lowercase, no https://)"; return 1
}
# ---- end prompts

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

if [ "${1:-}" = uninstall ]; then
  # Order matters: ArgoCD manages itself, so stop the self-management first or it deletes its own
  # controller and the remaining Applications hang on their finalizers.
  log "removing the platform (ArgoCD apps, then ArgoCD)"
  unfin() { kubectl -n argocd patch application "$1" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; }
  unfin app-of-apps; kubectl -n argocd delete application app-of-apps --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n argocd delete applicationsets --all --cascade=orphan >/dev/null 2>&1 || true
  unfin argocd; kubectl -n argocd delete application argocd --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n argocd delete applications --all --wait=true --timeout=5m || {
    log "some apps did not finish pruning: forcing"
    for a in $(kubectl -n argocd get applications -o name 2>/dev/null); do unfin "${a#*/}"; done; }
  kubectl -n argocd delete appprojects platform apps --ignore-not-found >/dev/null 2>&1 || true
  helm uninstall argocd -n argocd --wait 2>/dev/null || true
  log "done (namespaces, CRDs and PVCs are kept; delete them with kubectl if you want)"; exit 0
fi

HERE=""; if [ -f "${BASH_SOURCE[0]:-}" ]; then HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); fi
p_intro Essential "$HERE"
p_log "Kubernetes context: $(kubectl config current-context)"
KSTACK_REPO=${KSTACK_REPO:-}
while :; do
  p_text KSTACK_REPO "Your fork of kien-stack-essential (HTTPS URL)" "" v_url
  [ -n "$KSTACK_REPO" ] || die "a GitOps repo is required: fork $UPSTREAM first (or run https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh for a demo)"
  case "$KSTACK_REPO" in
    *kien-stack/essential*|*dedsxc/kien-stack-essential*)
      [ -n "$P_ON" ] || die "that is our public repo: use your fork (or try.sh for a demo)"
      p_log "${P_YE}▲  that is our public repo: use your fork (or try.sh for a demo)${P_0}"; KSTACK_REPO=""; continue ;;
  esac
  break
done
case "$KSTACK_REPO" in *.git) ;; *) KSTACK_REPO="$KSTACK_REPO.git" ;; esac
p_text KSTACK_BRANCH "Branch ArgoCD tracks" main

# Your fork, on your machine (a normal clone: you can edit and push from it later)
auth=()
[ -z "${GIT_TOKEN:-}" ] || auth=(-c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | base64 | tr -d '\n')")
SRC="$DIR/repo"
if [ -d "$SRC/.git" ]; then git -C "$SRC" ${auth[@]+"${auth[@]}"} pull -q --ff-only origin "$KSTACK_BRANCH" || die "cannot update $SRC (local changes?)"
else mkdir -p "$DIR"; git ${auth[@]+"${auth[@]}"} clone -q -b "$KSTACK_BRANCH" "$KSTACK_REPO" "$SRC" || die "cannot clone $KSTACK_REPO ($KSTACK_BRANCH)"; fi
cd "$SRC"
[ -f cluster.yaml ] && [ -f argocd/app-of-apps.yaml ] || die "$KSTACK_REPO does not look like a kien-stack-essential fork (no cluster.yaml / argocd/app-of-apps.yaml)"

if [ "$(yq -r .spec.source.repoURL argocd/app-of-apps.yaml)" = "$KSTACK_REPO" ] && [ "$(yq -r .global.domain cluster.yaml)" != example.com ]; then
  log "your fork is already configured (cluster.yaml: $(yq -r .global.domain cluster.yaml)): installing as is"
else
  ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  KSTACK_EMAIL=${KSTACK_EMAIL:-}; mode=""
  if [ -n "${KSTACK_DOMAIN:-}" ]; then mode=given
  else p_select mode "Domain" 1 "sslip.io (self-signed, for testing)|sslip" "My own domain + Let's Encrypt|own"; fi
  case "$mode" in
    own) p_text KSTACK_DOMAIN "Your domain, apps on <app>.<domain>" "" v_domain
         p_text KSTACK_EMAIL "Email for Let's Encrypt" "" v_email ;;
    given) p_text KSTACK_EMAIL "Email for Let's Encrypt (empty = self-signed certs)" "" v_email_opt ;;
    *)   KSTACK_DOMAIN="" ;;
  esac
  p_text KSTACK_IP "IP your browser uses to reach the cluster (Traefik node / LB)" "$ip" v_ip
  p_confirm KSTACK_CILIUM "Install Cilium? (only for a cluster created WITHOUT a CNI)" N
  dom=${KSTACK_DOMAIN:-$KSTACK_IP.sslip.io}
  tls=selfsigned; is=selfsigned-ca; [ -z "$KSTACK_EMAIL" ] || { tls=letsencrypt-http01; is=letsencrypt; }
  if [ "$KSTACK_CILIUM" = true ]; then cil=Yes; else cil=No; fi
  p_summary "Fork|$KSTACK_REPO" "Branch|$KSTACK_BRANCH" "Domain|$dom" "TLS|$tls${KSTACK_EMAIL:+ ($KSTACK_EMAIL)}" "IP|$KSTACK_IP" "Cilium|$cil" \
    || { p_outro "Nothing changed."; exit 0; }

  # 1. cluster.yaml: your settings
  D="$dom" T="$tls" I="$is" E="${KSTACK_EMAIL:-admin@$dom}" yq -i '
    .global.domain = strenv(D) | .global.tls.issuer = strenv(T) | .global.issuer = strenv(I) |
    .global.tls.email = strenv(E)' cluster.yaml
  # 2. argocd/: ArgoCD follows your fork
  R="$KSTACK_REPO" B="$KSTACK_BRANCH" yq -i '.spec.source.repoURL = strenv(R) | .spec.source.targetRevision = strenv(B)' argocd/app-of-apps.yaml
  for f in argocd/applications/*/appset.yaml; do
    R="$KSTACK_REPO" B="$KSTACK_BRANCH" yq -i '(.spec.generators[0] | select(has("git")) | .git) |= (.repoURL = strenv(R) | .revision = strenv(B)) |
      .spec.template.spec.source.repoURL = strenv(R) | .spec.template.spec.source.targetRevision = strenv(B)' "$f"
  done
  # 3. bricks: entries of the list in the platform ApplicationSet
  if [ "$KSTACK_CILIUM" = true ]; then
    yq -i '.spec.generators[0].list.elements += [{"app": "cilium", "namespace": "kube-system"}]' argocd/applications/platform/appset.yaml
    IP="$KSTACK_IP" yq -i '.cilium.k8sServiceHost = strenv(IP) | .cilium.k8sServicePort = 6443 |
      .cilium.ipam = {"mode": "cluster-pool", "operator": {"clusterPoolIPv4PodCIDRList": ["10.42.0.0/16"]}}' cluster.yaml
  fi
  # k3s & co already run a metrics-server: do not deploy ours
  if [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]; then
    yq -i 'del(.spec.generators[0].list.elements[] | select(.app == "metrics-server"))' argocd/applications/platform/appset.yaml
  fi
  [ "$tls" = selfsigned ] || log "Let's Encrypt HTTP-01: *.$dom must point to $KSTACK_IP, port 80 open from the Internet"

  gc=(); [ -n "$C_0" ] || gc=(-c color.ui=never)
  log "changes to your fork:"; git ${gc[@]+"${gc[@]}"} --no-pager diff --stat; git ${gc[@]+"${gc[@]}"} --no-pager diff -- cluster.yaml argocd/app-of-apps.yaml
  push=""; p_confirm push "Commit and push to $KSTACK_REPO ($KSTACK_BRANCH)?" Y
  [ "$push" = true ] || { p_end; die "nothing pushed. Your edited fork is in $SRC: push it, then run ./install.sh there"; }
  git -c user.name="${GIT_AUTHOR_NAME:-kien-stack}" -c user.email="${GIT_AUTHOR_EMAIL:-kien-stack@localhost}" \
    commit -qam "kien/stack: my settings (domain $dom)"
  git ${auth[@]+"${auth[@]}"} push -q origin "HEAD:$KSTACK_BRANCH" || die "push failed (write access to $KSTACK_REPO? set GIT_USERNAME/GIT_TOKEN). Your edited fork is in $SRC"
  log "pushed: $(git log -1 --format='%h %s')"
fi

p_outro "Installing…"
bash install.sh install  # KSTACK_VERBOSE (exported by --verbose) is read by install.sh
cat <<TXT

  Your fork: $SRC (cluster.yaml = your settings). Edit, commit, push: ArgoCD applies it.
  Our updates: merge new kien-stack-essential releases into your fork.

  AI Platform, Pro (SSO, backups, rollouts): https://shop.kien.cc
  Remove: curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash -s uninstall
TXT
