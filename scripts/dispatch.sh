#!/usr/bin/env bash
# Starts factory pipelines for cards waiting in the owner's queues. Run every 3 min.
# Pipelines run from a control checkout of origin/main (~/.pickio-factory/control), never from
# a worktree an agent can edit or from whatever branch the main checkout has.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${FACTORY_HOME:-$HOME/.pickio-factory}"
REPO="${FACTORY_REPO:-/c/Users/Kj/git/pickio}"
CONTROL="$HOME_DIR/control"
WT_ROOT="${FACTORY_WT_ROOT:-/c/Users/Kj/git/pickio-wt}"
CLAUDE="${FACTORY_CLAUDE:-claude}"
BOARD="${FACTORY_BOARD:-$HERE/board.sh}"
TTL="${FACTORY_LOCK_TTL:-10800}"
mkdir -p "$HOME_DIR/locks" "$HOME_DIR/logs" "$WT_ROOT"
[ -e "$HOME_DIR/PAUSE" ] && exit 0

refresh_control() {  # control checkout = exactly origin/main
  [ "${FACTORY_CONTROL_REFRESH:-1}" = "0" ] && return 0
  git -C "$REPO" fetch -q origin main || return 1
  if [ ! -e "$CONTROL/.git" ]; then
    git -C "$REPO" worktree add -q --detach "$CONTROL" origin/main || return 1
  fi
  git -C "$CONTROL" reset -q --hard origin/main && git -C "$CONTROL" clean -qfdx
}

lock_live() {  # lock_live <lock dir>: 0 = still held; an old lock whose process is gone is removed
  local dir="$1" pid epoch
  [ -d "$dir" ] || return 1
  read -r pid epoch _ < "$dir/info" 2>/dev/null || true
  [ -z "${epoch:-}" ] && epoch="$(stat -c %Y "$dir" 2>/dev/null || date +%s)"
  [ $(( $(date +%s) - epoch )) -le "$TTL" ] && return 0
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null && return 0
  rm -rf "$dir"; return 1
}

running_issues() {  # running_issues <pipeline>: issue numbers with a live lock (locks are per card)
  local d
  for d in "$HOME_DIR/locks/$1"-*.lock; do
    [ -d "$d" ] || continue
    lock_live "$d" && { d="${d##*-}"; echo "${d%.lock}"; }
  done
}

snapshot_status() { awk -F'\t' -v n="$1" '$1==n{print $2}' "$SNAP" 2>/dev/null; }

cleanup_processes() {  # stop node processes (dev servers, test runners) left in the card's worktree
  powershell.exe -NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { \$_.CommandLine -match 'pickio-wt[\\\\/]$1[\\\\/]' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null 2>&1 || true
}

launch() {  # launch <pipeline> <issue>
  local p="$1" n="$2" dir="$HOME_DIR/locks/$1-$2.lock"
  mkdir "$dir" 2>/dev/null || return 0
  local log="$HOME_DIR/logs/$(date +%F)-$n-$p.log"
  local extra=()
  [ "$p" = deployar ] && extra=(--allowedTools "Bash(gh pr merge:*)")  # only the deploy pipeline may merge
  (
    trap '' HUP
    echo "$BASHPID $(date +%s) $n" > "$dir/info"
    echo "== start /$p $n $(date -Is) pid=$BASHPID" >>"$log"
    # The prompt goes on stdin: as an argument Git Bash turns "/desenvolver 54" into
    # "C:/Program Files/Git/desenvolver 54", and MSYS_NO_PATHCONV would leak into mvn and break it.
    cd "$CONTROL" && printf '/%s %s' "$p" "$n" | PICKIO_FACTORY=1 "$CLAUDE" -p --permission-mode acceptEdits --add-dir "$WT_ROOT" --add-dir "$HOME_DIR" "${extra[@]}" >>"$log" 2>&1
    echo "== end /$p $n exit=$? $(date -Is)" >>"$log"
    read -r owner _ < "$dir/info" 2>/dev/null
    [ "${owner:-}" = "$BASHPID" ] && rm -rf "$dir"
    # a run that ended still holding the shared stack lock must not block the others
    local stack="$HOME_DIR/locks/stack.lock" held
    { read -r held _ < "$stack/info" || read -r held _ < "$stack/owner"; } 2>/dev/null
    [ "${held:-}" = "$p-$n" ] && rm -rf "$stack"
    [ "${FACTORY_CLEANUP:-1}" = 1 ] && cleanup_processes "$n"
  ) &
}

run_pipeline() {  # run_pipeline <name> <queue> <max runs> <wip-limit> <orphan columns, comma-separated> <wip column>...
  local p="$1" queue="$2" maxpar="$3" limit="$4" orphan_cols="$5"; shift 5
  local running n st inflight=0 free col cards refreshed=0 resumed=""
  running="$(running_issues "$p")"
  free=$(( maxpar - $(printf '%s' "$running" | grep -c .) ))
  [ "$free" -le 0 ] && return 0
  start_run() {
    if [ "$refreshed" = 0 ]; then
      refresh_control || { echo "dispatch: could not refresh $CONTROL from origin/main" >&2; return 1; }
      refreshed=1
    fi
    launch "$p" "$1"; running="$running"$'\n'"$1"; free=$((free - 1))
    if [ -n "${2:-}" ]; then resumed="$resumed $1"; fi  # resumed orphans already sit in a WIP column
  }
  # 1. resume orphans: cards this pipeline left mid-way (crash, usage limit) with no live run
  IFS=',' read -r -a cols <<< "$orphan_cols"
  for col in "${cols[@]}"; do
    [ -z "$col" ] && continue
    cards="$("$BOARD" eligible "$col")" || return 1
    for n in $cards; do
      [ "$free" -le 0 ] && return 0
      printf '%s\n' "$running" | grep -qx "$n" && continue
      start_run "$n" orphan || return 1
    done
  done
  # 2. new cards from the queue, within the WIP limit
  local slots="$free"
  if [ "$limit" -gt 0 ]; then
    local used; used="$("$BOARD" count "$@")" || return 1
    for n in $running; do  # runs whose card is not in a WIP column yet still take a WIP slot
      case " $resumed " in *" $n "*) continue ;; esac
      st="$(snapshot_status "$n")"; printf '%s\n' "$@" | grep -qxF "$st" || inflight=$((inflight + 1))
    done
    [ $(( limit - used - inflight )) -lt "$slots" ] && slots=$(( limit - used - inflight ))
  fi
  [ "$slots" -le 0 ] && return 0
  cards="$("$BOARD" eligible "$queue")" || return 1
  for n in $cards; do
    [ "$slots" -le 0 ] && break
    printf '%s\n' "$running" | grep -qx "$n" && continue
    start_run "$n" || return 1; slots=$((slots - 1))
  done
  return 0
}

usage_limited() {  # a run that ended on the Claude usage limit in the last 30 min pauses new launches
  local f
  for f in $(find "$HOME_DIR/logs" -name '*.log' -mmin -30 2>/dev/null); do
    awk '/^== start/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$f" | grep -q 'hit your session limit' && return 0
  done
  return 1
}

# One board read per run, shared by every check below (the GraphQL quota is shared with the pipelines).
SNAP="$HOME_DIR/board.tsv"
"$BOARD" snapshot > "$SNAP.tmp" || { rm -f "$SNAP.tmp"; echo "dispatch: board read failed" >&2; exit 1; }
mv "$SNAP.tmp" "$SNAP"
export FACTORY_BOARD_SNAPSHOT="$SNAP"

usage_limited && { echo "dispatch: Claude usage limit hit recently; waiting"; exit 0; }

status=0
run_pipeline refinar     "Ready for Refinement" 2 2 "Technical Refinement" "Spec Review"        || status=1
run_pipeline desenvolver "Ready for Dev"        2 4 "Coding,Validation"    "Coding" "Validation" || status=1
run_pipeline deployar    "Ready for Prod"       1 0 ""                                         || status=1
exit $status
