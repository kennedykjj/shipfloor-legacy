#!/usr/bin/env bash
# Starts factory pipelines for one project's cards waiting in the owner's queues. Run every
# 3 min by shipfloor-dispatch.sh, once per registered project. Pipelines run from the project's
# control checkout of origin/main, never from a worktree an agent can edit.
set -uo pipefail
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.; HERE="$(cd "$HERE" && pwd)"  # no dirname: one process less per start
source "$HERE/lib/project.sh"
source "$HERE/lib/stack.sh"
shipfloor_resolve . || exit 2
shipfloor_validate || { echo "dispatch: invalid config $FACTORY_CONFIG" | shipfloor_say "${MLANG:-en}" >&2; exit 2; }
HOME_DIR="${FACTORY_HOME:?FACTORY_HOME unset}"
REPO="${FACTORY_REPO:-}"
CONTROL="$HOME_DIR/control"
WT_ROOT="${FACTORY_WT_ROOT:-$HOME_DIR/wt}"
CLAUDE="${FACTORY_CLAUDE:-claude}"
PLUGIN="$(cat "$HERE/.source" 2>/dev/null || (cd "$HERE/.." && pwd))"  # the plugin checkout, as in scripts/shipfloor
BOARD="${FACTORY_BOARD:-$HERE/board.sh}"
TTL="${FACTORY_LOCK_TTL:-10800}"
export FACTORY_HOME="$HOME_DIR" FACTORY_WT_ROOT="$WT_ROOT" SHIPFLOOR_HOME
mkdir -p "$HOME_DIR/locks" "$HOME_DIR/logs" "$HOME_DIR/tmp" "$HOME_DIR/reviews" "$WT_ROOT"
[ -e "$HOME_DIR/PAUSE" ] && exit 0
mapfile -d '' -t LIM < <(shipfloor_cfg values limits.refine.wip limits.develop.wip)
[ "${#LIM[@]}" -eq 2 ] || { echo "dispatch: cannot read limits" | shipfloor_say "${MLANG:-en}" >&2; exit 2; }
# The machine pool (~/.shipfloor/config.yml): runs at once on this machine, and per stage, across projects.
shipfloor_machine validate || { echo "dispatch: invalid $SHIPFLOOR_HOME/config.yml" | shipfloor_say "${MLANG:-en}" >&2; exit 2; }
MLANG="$(shipfloor_machine values language 2>/dev/null | tr -d '\0')"
mapfile -d '' -t POOL < <(shipfloor_machine values pool stages.refine stages.develop stages.validate stages.deploy costs.card_block costs.day_stop)  # the cost limits ride on this read: none set, no estimate starts
[ "${#POOL[@]}" -eq 7 ] || { echo "dispatch: cannot read the machine pool" | shipfloor_say "${MLANG:-en}" >&2; exit 2; }
declare -A STAGE_SLOTS=([refine]="${POOL[1]}" [develop]="${POOL[2]}" [validate]="${POOL[3]}" [deploy]="${POOL[4]}")

refresh_control() {  # control checkout = exactly origin/main
  [ "${FACTORY_CONTROL_REFRESH:-1}" = "0" ] && return 0
  git -C "$REPO" fetch -q origin main || return 1
  if [ ! -e "$CONTROL/.git" ]; then
    git -C "$REPO" worktree add -q --detach "$CONTROL" origin/main || return 1
  fi
  git -C "$CONTROL" -c core.longpaths=true reset -q --hard origin/main && git -C "$CONTROL" -c core.longpaths=true clean -qfdx
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

card_busy() {  # card_busy <issue>: a live run of any pipeline holds this card (its worktree and tmp)
  local d
  for d in "$HOME_DIR"/locks/[a-z]*-"$1".lock; do [ -d "$d" ] && lock_live "$d" && return 0; done
  return 1
}

live_runs() {  # live_runs [stage]: live runs on this machine (every project), of one stage or all
  local d n=0 seen=" "
  local stage="${1:-}"; [ -n "$stage" ] || stage="[a-z]*"  # left unquoted below so it globs
  for d in "$SHIPFLOOR_HOME"/projects/*/locks/$stage-*.lock "$HOME_DIR"/locks/$stage-*.lock; do
    [ -d "$d" ] || continue
    case "${d##*/}" in refresh-*) continue ;; esac  # refreshes are scripts, not agents
    case "$seen" in *" $d "*) continue ;; esac
    seen="$seen$d "; lock_live "$d" && n=$((n + 1))
  done
  echo "$n"
}

snapshot_status() { awk -F'\t' -v n="$1" '$1==n{print $2}' "$SNAP" 2>/dev/null; }

cleanup_processes() {  # stop processes (dev servers, test runners) left running in the card's worktree
  command -v powershell.exe >/dev/null || return 0
  SHIPFLOOR_WT="$(shipfloor_native "$WT_ROOT/$1/")" powershell.exe -NoProfile -NonInteractive -Command '
    $p = [regex]::Escape($env:SHIPFLOOR_WT) -replace "/", "[\\/]"
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $p -and $_.ProcessId -ne $PID } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1 || true
}

read_rule() {  # read_rule <dir>: the permission rule that lets a run read under <dir>, never write; nothing when it does not exist
  local d; d="$(cd "$1" 2>/dev/null && pwd)" || return 0
  printf 'Read(/%s/**)' "$d"  # a rule's absolute path opens with two slashes
}

launch() {  # launch <pipeline> <issue>
  local p="$1" n="$2" dir="$HOME_DIR/locks/$1-$2.lock"
  mkdir "$dir" 2>/dev/null || return 0
  mkdir -p "$HOME_DIR/tmp/$n"  # the run's own scratch folder exists before it looks for one
  local log="$HOME_DIR/logs/$(date +%F)-$n-$p.log"
  # print mode stops background subagents 10 min after the last turn and ends the run half done; 0 waits
  # only the project's settings and this plugin: the owner's personal plugins, MCP servers and
  # output style cost every run ~19k tokens of context and steer its agents
  local extra=(--setting-sources project,local --strict-mcp-config --plugin-dir "$PLUGIN") envs=(SHIPFLOOR_FACTORY=1 "SHIPFLOOR_RUN_LOCK=$dir" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0)
  # A run reads the factory's scripts and templates and the reports of earlier runs (the skills send it there), and
  # writes neither. PowerShell is refused in every headless run; without the tool no turn is spent finding that out.
  local rule rules=(); for rule in "$(read_rule "$HERE")" "$(read_rule "$HOME_DIR/reports-wt")"; do [ -z "$rule" ] || rules+=("$rule"); done
  [ "${#rules[@]}" -eq 0 ] || extra+=(--allowedTools "${rules[@]}")
  extra+=(--disallowedTools PowerShell)
  # The owner's personal CLAUDE.md is loaded whatever the setting sources are: its memory and notes are not for a run.
  envs+=(CLAUDE_CODE_DISABLE_AUTO_MEMORY=1)
  extra+=(--append-system-prompt "This is an unattended factory run. A personal CLAUDE.md is for its owner's interactive sessions: what it says to read or write under ~/.claude (memory, journals, notes, a vault) does not apply here.")
  case "$p" in validate|deploy) extra+=(--model sonnet) ;; esac  # orchestration and conflict fixes: half the price
  local retry=0; [ -e "$HOME_DIR/infra/$n" ] && { retry=1; envs+=(SHIPFLOOR_INFRA_RETRY=1); }
  (
    trap '' HUP
    echo "$BASHPID $(date +%s) $n" > "$dir/info"
    echo "== start /sf:$p $n $(date -Is) pid=$BASHPID" >>"$log"
    # The prompt goes on stdin: as an argument Git Bash turns "/develop 54" into
    # "C:/Program Files/Git/develop 54", and MSYS_NO_PATHCONV would leak into mvn and break it.
    agent() { printf '/sf:%s %s' "$p" "$n" | env -u FACTORY_BOARD_SNAPSHOT "${envs[@]}" "$CLAUDE" -p --permission-mode acceptEdits       --add-dir "$WT_ROOT" --add-dir "$HOME_DIR/tmp" --add-dir "$HOME_DIR/reviews" "${extra[@]}" >>"$log" 2>&1; }
    cd "$CONTROL" || exit 1
    if [ "$p" = deploy ]; then
      # The deploy is a script, not an agent: it can wait for CI and production as long as needed.
      # An agent is called only for what the script hands over (exit 3): merge conflicts with main, then up to
      # two rounds on a gate or CI that went red on top of main.
      local dep="${FACTORY_DEPLOY:-$HERE/deploy.sh}" rc round
      env -u FACTORY_BOARD_SNAPSHOT "${envs[@]}" bash "$dep" "$n" >>"$log" 2>&1; rc=$?
      for round in 1 2 3; do
        [ "$rc" = 3 ] || break
        agent; env -u FACTORY_BOARD_SNAPSHOT "${envs[@]}" bash "$dep" "$n" --continue >>"$log" 2>&1; rc=$?
      done
      echo "== end /sf:$p $n exit=$rc $(date -Is)" >>"$log"
    else
      agent; echo "== end /sf:$p $n exit=$? $(date -Is)" >>"$log"
    fi
    # what the run created goes with it, before its lock: its stack slot, its tmp/<n>/, its retry marker
    stack_settings; stack_release_run "$dir"
    shipfloor_clean_tmp "$n"  # the retry's marker stays: it is how the next block goes to the owner
    [ "${FACTORY_CLEANUP:-1}" = 1 ] && cleanup_processes "$n"
    read -r owner _ < "$dir/info" 2>/dev/null
    [ "${owner:-}" = "$BASHPID" ] && rm -rf "$dir"
  ) &
}

run_pipeline() {  # run_pipeline <name> <queue> <max runs in this project, 0 = the stage slots decide> <wip-limit> <orphan columns, comma-separated> <wip column>...
  local p="$1" queue="$2" maxpar="$3" limit="$4" orphan_cols="$5"; shift 5
  local running n st inflight=0 free col cards refreshed=0 resumed=""
  running="$(running_issues "$p")"
  free=$(( maxpar - $(printf '%s' "$running" | grep -c .) ))
  local stage_free=$(( ${STAGE_SLOTS[$p]:-0} - $(live_runs "$p") ))
  { [ "$maxpar" -eq 0 ] || [ "$stage_free" -lt "$free" ]; } && free="$stage_free"  # 0 = the stage slots decide
  [ "$free" -le 0 ] && return 0
  start_run() {
    STARTED=0
    case " $BLOCK_CARDS " in *" $1 "*) block_card "$1" && return 0 ;; esac  # blocked, not started: it takes no slot
    STARTED=1
    if [ "$refreshed" = 0 ]; then
      refresh_control || { echo "dispatch: could not refresh $CONTROL from origin/main" | shipfloor_say "${MLANG:-en}" >&2; return 1; }
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
      card_busy "$n" && continue
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
    card_busy "$n" && continue
    start_run "$n" || return 1
    [ "$STARTED" = 1 ] && slots=$((slots - 1))
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
# A temp file per process: two dispatches at once must not write, or move away, each other's.
"$BOARD" snapshot > "$SNAP.$$.tmp" || { rm -f "$SNAP.$$.tmp"; echo "dispatch: board read failed" | shipfloor_say "${MLANG:-en}" >&2; exit 1; }
mv "$SNAP.$$.tmp" "$SNAP"
export FACTORY_BOARD_SNAPSHOT="$SNAP"

usage_limited && { echo "dispatch: Claude usage limit hit recently; waiting" | shipfloor_say "${MLANG:-en}"; exit 0; }

# Cost limits (machine config `costs`): none set, nothing below starts a process. A marker cost/<n>.json
# (the baseline of a block) goes when its card leaves the board. An empty board read proves nothing: it keeps them.
if grep -q . "$SNAP" 2>/dev/null; then
  for f in "$HOME_DIR"/cost/*.json; do
    [ -f "$f" ] || continue; n="${f##*/}"; n="${n%.json}"
    [ -n "$(snapshot_status "$n")" ] || rm -f "$f"
  done
fi
BLOCK_CARDS=""
if [ -n "${POOL[5]}${POOL[6]}" ]; then
  shipfloor_py
  COST_PY=("$SHIPFLOOR_PY" -I "$(shipfloor_native "$HERE/dashboard_cost.py")")
  COST_ARGS=(--home "$(shipfloor_native "$SHIPFLOOR_HOME")" --project "${FACTORY_PROJECT:?}")
  limits="$("${COST_PY[@]}" limits "${COST_ARGS[@]}" | tr -d '\r')" || { echo "dispatch: cannot read the cost limits" | shipfloor_say "${MLANG:-en}" >&2; exit 1; }
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      day_stop) echo "dispatch: today's estimate US$ $a reached costs.day_stop (US$ $b); no new run until tomorrow" | shipfloor_say "${MLANG:-en}"; exit 0 ;;
      block) BLOCK_CARDS="$BLOCK_CARDS $a" ;;
    esac
  done <<< "$limits"
fi
STARTED=0 COSTFAIL=0

block_card() {  # block_card <issue>: the comment says why, then the label; a failure of either fails the cycle
  local n="$1" m="$HOME_DIR/cost/$1.json" body="$HOME_DIR/tmp/cost-$1.md" rc=0 gh="${FACTORY_GH:-gh}"
  cp "$m" "$m.prev" 2>/dev/null
  "${COST_PY[@]}" block "${COST_ARGS[@]}" --issue "$n" --out "$(shipfloor_native "$body")" || rc=$?
  if [ "$rc" = 1 ]; then rm -f "$m.prev"; return 1; fi  # no known estimate: never judged, it starts
  if [ "$rc" = 0 ]; then
    "$gh" issue comment "$n" ${REPO:+-R "$REPO"} --body-file "$body" >/dev/null && "$BOARD" label "$n" add blocked && { rm -f "$m.prev" "$body"; echo "dispatch: #$n reached costs.card_block; blocked" | shipfloor_say "${MLANG:-en}"; return 0; }
    rc=1
  fi
  # not told: put the marker back, or the next cycle would take this block for done and start the card
  if [ -f "$m.prev" ]; then mv -f "$m.prev" "$m"; else rm -f "$m"; fi
  rm -f "$body"; COSTFAIL=1; echo "dispatch: could not block #$n at costs.card_block" | shipfloor_say "${MLANG:-en}" >&2
  return 0
}

refresh_staged() {  # keep approved-to-be PRs on top of main: deploy.sh --refresh, a script, no agent slot
  local n dir log cards
  cards="$("$BOARD" eligible Staged)" || return 1
  for n in $cards; do
    card_busy "$n" && continue
    dir="$HOME_DIR/locks/refresh-$n.lock"; mkdir "$dir" 2>/dev/null || continue
    log="$HOME_DIR/logs/$(date +%F)-$n-refresh.log"
    (
      trap '' HUP
      echo "$BASHPID $(date +%s) $n" > "$dir/info"
      cd "$CONTROL" && env -u FACTORY_BOARD_SNAPSHOT bash "${FACTORY_DEPLOY:-$HERE/deploy.sh}" "$n" --refresh >>"$log" 2>&1
      rm -rf "$dir"
    ) &
  done
}

retry_infra() {  # cards blocked by infrastructure: clean up and retry once; a second block goes to the owner
  local n f cards; cards="$("$BOARD" infra)" || return 1
  mkdir -p "$HOME_DIR/infra"
  for f in "$HOME_DIR"/infra/*; do  # a marker whose card is no longer blocked by infrastructure is spent
    [ -f "$f" ] || continue; n="${f##*/}"
    printf '%s\n' $cards | grep -qx "$n" || card_busy "$n" || rm -f "$f"
  done
  for n in $cards; do
    card_busy "$n" && continue
    if [ -e "$HOME_DIR/infra/$n" ]; then
      "$BOARD" label "$n" add blocked; "$BOARD" label "$n" remove blocked:infra; rm -f "$HOME_DIR/infra/$n"; continue
    fi
    shipfloor_clean_tmp "$n"; date +%s > "$HOME_DIR/infra/$n"; "$BOARD" label "$n" remove blocked:infra
  done
}

GLOBAL=$(( ${SHIPFLOOR_MAX_PARALLEL:-${POOL[0]}} - $(live_runs) ))
status=0
retry_infra || status=1
# Outside the working hours (config.yml, hours) only the starts are skipped; the rest of the cycle runs as always.
read -r hours_state hours_next < <(shipfloor_machine hours 2>/dev/null)
if [ "${hours_state:-open}" = closed ]; then
  echo "dispatch: outside working hours; runs start again at $hours_next" | shipfloor_say "${MLANG:-en}"
else
  run_pipeline refine     "Ready for Refinement" 0           "${LIM[0]}" "Technical Refinement" "Spec Review"        || status=1
  run_pipeline develop "Ready for Dev"        0           "${LIM[1]}" "Coding"               "Coding" "Validation" || status=1
  run_pipeline validate     "Validation"           0           0          ""                                         || status=1
  # one deploy at a time in a project: merges into its main are serial
  run_pipeline deploy    "Ready for Prod"       1           0          ""                                         || status=1
fi
# Off by default: every refresh push reruns the whole CI (Actions minutes on GitHub Free).
[ "$(shipfloor_cfg get deploy.refresh_staged 2>/dev/null)" = true ] && { refresh_staged || status=1; }
[ "$COSTFAIL" = 1 ] && status=1
# What finished cards and stray files left under tmp/ goes with every cycle (the same as `shipfloor clean`).
shipfloor_sweep_tmp | sed "s|^|$(date -Is) dispatch: removed |"
exit $status
