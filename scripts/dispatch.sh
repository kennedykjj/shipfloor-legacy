#!/usr/bin/env bash
# Starts factory pipelines for one project's cards waiting in the owner's queues. Run every
# 3 min by mylos-dispatch.sh, once per registered project. Pipelines run from the project's
# control checkout of origin/main, never from a worktree an agent can edit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/project.sh"
mylos_resolve . || exit 2
mylos_validate || { echo "dispatch: invalid config $FACTORY_CONFIG" >&2; exit 2; }
HOME_DIR="${FACTORY_HOME:?FACTORY_HOME unset}"
REPO="${FACTORY_REPO:-}"
CONTROL="$HOME_DIR/control"
WT_ROOT="${FACTORY_WT_ROOT:-$HOME_DIR/wt}"
CLAUDE="${FACTORY_CLAUDE:-claude}"
BOARD="${FACTORY_BOARD:-$HERE/board.sh}"
TTL="${FACTORY_LOCK_TTL:-10800}"
export FACTORY_HOME="$HOME_DIR" FACTORY_WT_ROOT="$WT_ROOT" MYLOS_HOME
mkdir -p "$HOME_DIR/locks" "$HOME_DIR/logs" "$HOME_DIR/tmp" "$HOME_DIR/reviews" "$WT_ROOT"
[ -e "$HOME_DIR/PAUSE" ] && exit 0
mapfile -d '' -t LIM < <(mylos_cfg values limits.refinar.parallel limits.refinar.wip \
  limits.desenvolver.parallel limits.desenvolver.wip limits.validar.parallel limits.deployar.parallel)
[ "${#LIM[@]}" -eq 6 ] || { echo "dispatch: cannot read limits" >&2; exit 2; }
# The machine pool (~/.mylos/config.yml): runs at once on this machine, and per stage, across projects.
mylos_machine validate || { echo "dispatch: invalid $MYLOS_HOME/config.yml" >&2; exit 2; }
mapfile -d '' -t POOL < <(mylos_machine values pool stages.refinar stages.desenvolver stages.validar stages.deployar)
[ "${#POOL[@]}" -eq 5 ] || { echo "dispatch: cannot read the machine pool" >&2; exit 2; }
declare -A STAGE_SLOTS=([refinar]="${POOL[1]}" [desenvolver]="${POOL[2]}" [validar]="${POOL[3]}" [deployar]="${POOL[4]}")

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
  { read -r pid epoch _ < "$dir/info"; } 2>/dev/null || true
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

live_runs() {  # live_runs [stage]: live runs on this machine (every project), of one stage or all
  local d n=0 seen=" "
  local stage="${1:-}"; [ -n "$stage" ] || stage="[a-z]*"  # left unquoted below so it globs
  for d in "$MYLOS_HOME"/projects/*/locks/$stage-*.lock "$HOME_DIR"/locks/$stage-*.lock; do
    [ -d "$d" ] || continue
    case "$seen" in *" $d "*) continue ;; esac
    seen="$seen$d "; lock_live "$d" && n=$((n + 1))
  done
  echo "$n"
}

snapshot_status() { awk -F'\t' -v n="$1" '$1==n{print $2}' "$SNAP" 2>/dev/null; }

cleanup_processes() {  # stop processes (dev servers, test runners) left running in the card's worktree
  command -v powershell.exe >/dev/null || return 0
  MYLOS_WT="$(mylos_native "$WT_ROOT/$1/")" powershell.exe -NoProfile -NonInteractive -Command '
    $p = [regex]::Escape($env:MYLOS_WT) -replace "/", "[\\/]"
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $p -and $_.ProcessId -ne $PID } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1 || true
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
    echo "== start /mylos:$p $n $(date -Is) pid=$BASHPID" >>"$log"
    # The prompt goes on stdin: as an argument Git Bash turns "/desenvolver 54" into
    # "C:/Program Files/Git/desenvolver 54", and MSYS_NO_PATHCONV would leak into mvn and break it.
    cd "$CONTROL" && printf '/mylos:%s %s' "$p" "$n" | MYLOS_FACTORY=1 "$CLAUDE" -p --permission-mode acceptEdits       --add-dir "$WT_ROOT" --add-dir "$HOME_DIR/tmp" --add-dir "$HOME_DIR/reviews" "${extra[@]}" >>"$log" 2>&1
    echo "== end /mylos:$p $n exit=$? $(date -Is)" >>"$log"
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
  local stage_free=$(( ${STAGE_SLOTS[$p]:-0} - $(live_runs "$p") ))
  [ "$stage_free" -lt "$free" ] && free="$stage_free"
  [ "$free" -le 0 ] && return 0
  start_run() {
    if [ "$refreshed" = 0 ]; then
      refresh_control || { echo "dispatch: could not refresh $CONTROL from origin/main" >&2; return 1; }
      refreshed=1
    fi
    launch "$p" "$1"; running="$running"$'\n'"$1"; free=$((free - 1)); GLOBAL=$((GLOBAL - 1))
    if [ -n "${2:-}" ]; then resumed="$resumed $1"; fi  # resumed orphans already sit in a WIP column
  }
  # 1. resume orphans: cards this pipeline left mid-way (crash, usage limit) with no live run
  IFS=',' read -r -a cols <<< "$orphan_cols"
  for col in "${cols[@]}"; do
    [ -z "$col" ] && continue
    cards="$("$BOARD" eligible "$col")" || return 1
    for n in $cards; do
      { [ "$free" -le 0 ] || [ "$GLOBAL" -le 0 ]; } && return 0
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
    { [ "$slots" -le 0 ] || [ "$GLOBAL" -le 0 ]; } && break
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

GLOBAL=$(( ${MYLOS_MAX_PARALLEL:-${POOL[0]}} - $(live_runs) ))
status=0
run_pipeline refinar     "Ready for Refinement" "${LIM[0]}" "${LIM[1]}" "Technical Refinement" "Spec Review"        || status=1
run_pipeline desenvolver "Ready for Dev"        "${LIM[2]}" "${LIM[3]}" "Coding"               "Coding" "Validation" || status=1
run_pipeline validar     "Validation"           "${LIM[4]}" 0           ""                                         || status=1
run_pipeline deployar    "Ready for Prod"       "${LIM[5]}" 0           ""                                         || status=1
exit $status
