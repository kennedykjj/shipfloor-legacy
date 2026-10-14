#!/usr/bin/env bash
# #160 AC-1, AC-7: the dispatcher's process model, pinned as it is today (PY-15 ports it). The launch is the real
# one: dispatch.sh forks the run, FACTORY_CLAUDE is a real script that sleeps and writes, and no helper joins the run
# (run_dispatch is not used): the cycle returns while the run lives, and each test waits for the files the run writes.
#  - a run outlives its cycle, ends on its own, removes only its own lock and logs "== end"
#  - SIGHUP to the cycle does not stop a run
#  - the lock dir exists as soon as launch returns, before the child writes info (the next count sees it)
#  - FACTORY_LOCK_TTL: young lock with a dead pid is live; old lock with a dead pid is removed while counting
#  - the deploy loop stops after 3 rounds of exit 3
#  - refresh-<n>.lock and <date>-<n>-refresh.log; refresh-* is not counted as a run
#  - cleanup_processes with powershell.exe stubbed targets only $WT_ROOT/<n>/
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
BASE_CONFIG="$FACTORY_CONFIG"
TMPS=()
# every sleeping child is released or killed when the test ends, whatever happened
cleanup() {
  local t p
  for t in "${TMPS[@]}"; do
    rm -f "$t/hold" "$t/holddate" "$t/holdboard" "$t/holdrefresh"
    [ -f "$t/claude.pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$t/claude.pids"
    [ -f "$t/cycle.pid" ] && kill "$(cat "$t/cycle.pid")" 2>/dev/null
  done
  return 0
}
trap cleanup EXIT

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
lines() { grep -c . "$1" 2>/dev/null || echo 0; }
ended() { grep -q "== end /sf:$1 $2 " "$FACTORY_HOME"/logs/*-"$2-$1.log" 2>/dev/null; }
lock_gone() { [ ! -d "$FACTORY_HOME/locks/$1.lock" ]; }
alive() { kill -0 "$1" 2>/dev/null; }
dead_pid() { sh -c ':' & local p=$!; wait "$p"; echo "$p"; }
log_of() { cat "$FACTORY_HOME"/logs/*-"$2-$1.log" 2>/dev/null; }

fresh() {  # fresh: a new factory home, wt root, T dir and fake board / claude / deploy; nothing queued, nothing held
  T="$(mktemp -d)"; TMPS+=("$T")
  export T FACTORY_HOME="$(mktemp -d)" SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  unset FACTORY_LOCK_TTL SHIPFLOOR_MAX_PARALLEL DEPLOY_THREES CLAUDE_EXIT
  export Q_REF= Q_DEV= Q_PROD= Q_STAGED=
  mkdir -p "$FACTORY_HOME/control" "$T/bin"
  printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Refinement") echo "${Q_REF:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Ready for Prod") echo "${Q_PROD:-}" ;;
  "eligible Staged") echo "${Q_STAGED:-}" ;;
  "eligible Validation")  # asked after develop's launch: the cycle is still running while this waits
    : > "$T/board-asked"
    n=0; while [ -e "$T/holdboard" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done ;;
  "eligible "*) ;;
  *) echo 0 ;;
esac
EOB
  # the run: it writes its pid and what it was asked, sleeps (while $T/hold exists, and at least 0.2 s), writes again
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
prompt="$(cat)"
echo "$$" >> "$T/claude.pids"
echo "$prompt" >> "$T/claude.calls"
echo "claude: working on $prompt"
n=0; while [ -e "$T/hold" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
sleep 0.2
echo "claude: finished $prompt"
exit "${CLAUDE_EXIT:-0}"
EOC
  # the deploy script: exit 3 (hand over to an agent) for its first ${DEPLOY_THREES:-99} calls; --refresh waits for $T/holdrefresh
  cat > "$T/deploy" <<'EOD'
#!/usr/bin/env bash
echo "$*" >> "$T/deploy.calls"
if [ "${2:-}" = --refresh ]; then
  n=0; while [ -e "$T/holdrefresh" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
  echo "refresh ran for $1"; exit 0
fi
c="$(grep -vc -e '--refresh' "$T/deploy.calls")"
echo "deploy call $c: $*"
[ "$c" -le "${DEPLOY_THREES:-99}" ] && exit 3
exit 0
EOD
  chmod +x "$T/board" "$T/claude" "$T/deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude" FACTORY_DEPLOY="$T/deploy"
}
cycle() { bash "$D" >"$T/out" 2>&1; CRC=$?; }  # one dispatch.sh cycle; it returns as soon as it has launched, not when the run ends

# ---- AC-1 (and AC-7): a run outlives its cycle, ends on its own, removes only its own lock, logs == end
fresh; export Q_DEV=54; touch "$T/hold"
mkdir -p "$FACTORY_HOME/locks/refine-77.lock"; echo "$$ $(date +%s) 77" > "$FACTORY_HOME/locks/refine-77.lock/info"  # another card's run
cycle
lock="$FACTORY_HOME/locks/develop-54.lock"
t "AC-7 FACTORY_CLAUDE is a real script that sleeps and writes (no stub replaces the launch)" grep -q 'sleep' "$FACTORY_CLAUDE"
t "AC-1 the cycle returned with exit 0 while the run is not over" test "$CRC" = 0
wait_for "the run's claude to start" test -s "$T/claude.pids"
cpid="$(head -n1 "$T/claude.pids")"; read -r rpid _ < "$lock/info" 2>/dev/null
t "AC-1 after the cycle returned, the run's own process is still alive" alive "$rpid"
t "AC-1 after the cycle returned, claude is still alive" alive "$cpid"
t "AC-1 the run's lock is held while it works" test -d "$lock"
t "AC-7 the real claude script was started with the card's prompt on stdin" grep -qx '/sf:develop 54' "$T/claude.calls"
t "AC-7 the run's log holds what claude wrote" grep -q 'claude: working on /sf:develop 54' <<< "$(log_of develop 54)"
t "AC-1 no == end line while the run is alive" not grep -q '== end' <<< "$(log_of develop 54)"
t "AC-1 the start line carries the run's pid" grep -q "== start /sf:develop 54 .* pid=$rpid" <<< "$(log_of develop 54)"
rm -f "$T/hold"
wait_for "the run to log == end" ended develop 54
wait_for "the run to remove its lock" lock_gone develop-54
wait_for "the run's process to end" not alive "$rpid"
t "AC-1 the run ends with == end /sf:develop 54 exit=0" grep -q '== end /sf:develop 54 exit=0 ' <<< "$(log_of develop 54)"
t "AC-1 claude finished its work (it was not cut short)" grep -q 'claude: finished /sf:develop 54' <<< "$(log_of develop 54)"
t "AC-1 the run removed its own lock" lock_gone develop-54
t "AC-1 the run left another card's lock alone" test -d "$FACTORY_HOME/locks/refine-77.lock"

# the run removes only its own lock: a lock whose info names another owner by the time the run ends stays
fresh; export Q_DEV=54; touch "$T/hold"; cycle
wait_for "the run's claude to start" test -s "$T/claude.pids"
lock="$FACTORY_HOME/locks/develop-54.lock"; read -r rpid _ < "$lock/info"
echo "1 $(date +%s) 54" > "$lock/info"  # someone else owns the lock now
rm -f "$T/hold"
wait_for "the run to log == end" ended develop 54
wait_for "the run's process to end" not alive "$rpid"
t "AC-1 a lock owned by another pid is not removed by the run" test -d "$lock"
t "AC-1 ... and the run still logged == end" ended develop 54

# ---- AC-1: SIGHUP to the cycle does not stop a run
fresh; export Q_DEV=54; touch "$T/hold" "$T/holdboard"
bash "$D" >"$T/out" 2>&1 &
cyc=$!; echo "$cyc" > "$T/cycle.pid"
wait_for "the run's claude to start" test -s "$T/claude.pids"
wait_for "the cycle to go on to the next queue" test -e "$T/board-asked"
lock="$FACTORY_HOME/locks/develop-54.lock"; cpid="$(head -n1 "$T/claude.pids")"; read -r rpid _ < "$lock/info"
t "AC-1 before the HUP, the cycle is alive" alive "$cyc"
kill -HUP "$cyc" "$rpid" "$cpid" 2>/dev/null
wait "$cyc"; hrc=$?
t "AC-1 SIGHUP ends the cycle (exit 129)" test "$hrc" = 129
t "AC-1 after SIGHUP to the cycle (and to the run), the run is alive" alive "$rpid"
t "AC-1 after SIGHUP, claude is alive" alive "$cpid"
rm -f "$T/hold" "$T/holdboard"
wait_for "the run to log == end" ended develop 54
t "AC-1 a run that got SIGHUP finished its work" grep -q 'claude: finished /sf:develop 54' <<< "$(log_of develop 54)"
t "AC-1 ... and ended with exit=0" grep -q '== end /sf:develop 54 exit=0 ' <<< "$(log_of develop 54)"
wait_for "the run to remove its lock" lock_gone develop-54

# ---- AC-1: the lock dir exists as soon as launch returns, before the child writes info
# a date that waits, once, when asked for the epoch while the lock dir exists with no info: the child's first act is
# `echo "$BASHPID $(date +%s) $n" > info`, so the child is held right between the lock and its info
fresh; export Q_DEV=54
{ echo '#!/usr/bin/env bash'; echo "REAL=\"$(command -v date)\""; cat <<'EOS'
l="$FACTORY_HOME/locks/develop-54.lock"
if [ "${1:-}" = +%s ] && [ -e "$T/holddate" ] && [ -d "$l" ] && [ ! -e "$l/info" ] && mkdir "$T/date-held" 2>/dev/null; then
  n=0; while [ -e "$T/holddate" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
fi
exec "$REAL" "$@"
EOS
} > "$T/bin/date"; chmod +x "$T/bin/date"
touch "$T/holddate"
lock="$FACTORY_HOME/locks/develop-54.lock"
PATH="$T/bin:$PATH" bash "$D" >"$T/out" 2>&1; CRC=$?
t "AC-1 the cycle returned while the child is held before it wrote info" test "$CRC" = 0
t "AC-1 the lock dir exists as soon as launch returns" test -d "$lock"
t "AC-1 ... before the child has written info" test ! -e "$lock/info"
t "AC-1 the child really is held (nothing started yet)" test ! -e "$T/claude.calls"
PATH="$T/bin:$PATH" bash "$D" >"$T/out2" 2>&1; CRC2=$?   # the next cycle counts the lock that has no info yet
t "AC-1 the next count sees the lock: the next cycle exits 0" test "$CRC2" = 0
t "AC-1 ... and the lock is still there" test -d "$lock"
rm -f "$T/holddate"
wait_for "the run to log == end" ended develop 54
wait_for "the run to remove its lock" lock_gone develop-54
t "AC-1 the next cycle did not start a second run for the card (one claude call)" test "$(lines "$T/claude.calls")" = 1
t "AC-1 ... and the log has one start line" test "$(grep -c '^== start' <<< "$(log_of develop 54)")" = 1

# ---- AC-1: FACTORY_LOCK_TTL
now="$(date +%s)"; dead="$(dead_pid)"
fresh; export Q_REF=25 FACTORY_LOCK_TTL=100
mkdir -p "$FACTORY_HOME/locks/refine-25.lock"; echo "$dead $(( now - 50 )) 25" > "$FACTORY_HOME/locks/refine-25.lock/info"
cycle
t "AC-1 a lock younger than the TTL counts as live even with a dead pid: the card is not started" test ! -e "$T/claude.calls"
t "AC-1 ... and the lock is not removed" test -d "$FACTORY_HOME/locks/refine-25.lock"
fresh; export Q_REF=25 FACTORY_LOCK_TTL=100
mkdir -p "$FACTORY_HOME/locks/refine-25.lock"; echo "$$ $(( now - 200 )) 25" > "$FACTORY_HOME/locks/refine-25.lock/info"
cycle
t "AC-1 a lock older than the TTL whose pid is alive stays live: the card is not started" test ! -e "$T/claude.calls"
t "AC-1 ... and the lock is not removed" test -d "$FACTORY_HOME/locks/refine-25.lock"
fresh; export Q_REF=25 FACTORY_LOCK_TTL=100
mkdir -p "$FACTORY_HOME/locks/refine-25.lock"; echo "$dead $(( now - 200 )) 25" > "$FACTORY_HOME/locks/refine-25.lock/info"
cycle
wait_for "the run of the card whose old lock was removed" ended refine 25
wait_for "the new run to remove its lock" lock_gone refine-25
t "AC-1 a lock older than the TTL with a dead pid is replaced: the card is started" grep -qx '/sf:refine 25' "$T/claude.calls"
# removed while counting: no card is queued, the count alone clears the old dead lock and leaves the young one
fresh; export FACTORY_LOCK_TTL=100
for l in validate-31:200 validate-32:50 develop-33:200; do
  mkdir -p "$FACTORY_HOME/locks/${l%%:*}.lock"; echo "$dead $(( now - ${l##*:} )) x" > "$FACTORY_HOME/locks/${l%%:*}.lock/info"
done
cycle
t "AC-1 counting removes an old lock with a dead pid (validate)" lock_gone validate-31
t "AC-1 counting removes an old lock with a dead pid (develop)" lock_gone develop-33
t "AC-1 counting keeps a young lock with a dead pid" test -d "$FACTORY_HOME/locks/validate-32.lock"
unset FACTORY_LOCK_TTL

# ---- AC-1: the deploy loop stops after 3 rounds of exit 3
fresh; export Q_PROD=47
cycle
wait_for "the deploy run to log == end" ended deploy 47
wait_for "the deploy run to remove its lock" lock_gone deploy-47
t "AC-1 deploy.sh runs once, then once per round with --continue: 4 calls for 3 rounds" test "$(lines "$T/deploy.calls")" = 4
t "AC-1 the first call has no --continue" test "$(sed -n 1p "$T/deploy.calls")" = 47
t "AC-1 the next three calls are --continue" test "$(sed -n '2,4p' "$T/deploy.calls" | grep -cx '47 --continue')" = 3
t "AC-1 an agent is called once per round: 3 times, never a fourth" test "$(grep -cx '/sf:deploy 47' "$T/claude.calls")" = 3
t "AC-1 after 3 rounds the run ends with the last exit code (3)" grep -q '== end /sf:deploy 47 exit=3 ' <<< "$(log_of deploy 47)"
fresh; export Q_PROD=47 DEPLOY_THREES=2
cycle
wait_for "the deploy run to log == end" ended deploy 47
wait_for "the deploy run to remove its lock" lock_gone deploy-47
t "AC-1 when deploy.sh hands over twice and then succeeds, the loop stops: 2 agent calls, 3 deploy calls" test "$(lines "$T/claude.calls")-$(lines "$T/deploy.calls")" = 2-3
t "AC-1 ... and the run ends with exit=0" grep -q '== end /sf:deploy 47 exit=0 ' <<< "$(log_of deploy 47)"
unset DEPLOY_THREES

# ---- AC-1: refresh-<n>.lock, <date>-<n>-refresh.log, and refresh-* is not a run
fresh; export Q_STAGED=61 Q_DEV=; touch "$T/holdrefresh"
sed 's/environment: production}/environment: production, refresh_staged: true}/' "$FACTORY_DIR/test/fixture/factory.yml" > "$T/factory.yml"
export FACTORY_CONFIG="$T/factory.yml"
cycle
rl="$FACTORY_HOME/locks/refresh-61.lock"; rlog="$FACTORY_HOME/logs/$(date +%F)-61-refresh.log"
wait_for "the refresh script to start" test -s "$T/deploy.calls"
t "AC-1 the refresh takes the lock refresh-<n>.lock" test -d "$rl"
t "AC-1 ... with an info file naming its pid, epoch and card" grep -Eq '^[0-9]+ [0-9]+ 61$' "$rl/info"
t "AC-1 the refresh runs deploy.sh <n> --refresh" grep -qx '61 --refresh' "$T/deploy.calls"
t "AC-1 the refresh log is <date>-<n>-refresh.log" test -f "$rlog"
export SHIPFLOOR_MAX_PARALLEL=1 Q_DEV=54
cycle
wait_for "the develop run beside the refresh" ended develop 54
wait_for "the develop run to remove its lock" lock_gone develop-54
t "AC-1 a refresh lock is not a run: with room for one run, a develop run starts beside it" grep -qx '/sf:develop 54' "$T/claude.calls"
rm -f "$T/holdrefresh"
wait_for "the refresh to remove its lock" lock_gone refresh-61
t "AC-1 the refresh log has what the script wrote" grep -q 'refresh ran for 61' "$rlog"
# the same room is taken by a real run
fresh; export SHIPFLOOR_MAX_PARALLEL=1 Q_DEV=54
mkdir -p "$FACTORY_HOME/locks/develop-5.lock"; echo "$$ $(date +%s) 5" > "$FACTORY_HOME/locks/develop-5.lock/info"
cycle
t "AC-1 contrast: with the room taken by a live develop run, nothing starts" test ! -e "$T/claude.calls"
unset SHIPFLOOR_MAX_PARALLEL

# ---- AC-1: cleanup_processes with powershell.exe stubbed
fresh; export Q_DEV="54 55"
cat > "$T/bin/powershell.exe" <<'EOP'
#!/usr/bin/env bash
{ echo "wt=$SHIPFLOOR_WT"; echo "args=$*"
  for l in develop-54 develop-55; do [ -d "$FACTORY_HOME/locks/$l.lock" ] && echo "lock-present $l"; done; echo "--"; } >> "$T/ps.calls"
EOP
chmod +x "$T/bin/powershell.exe"
FACTORY_CLEANUP=1 PATH="$T/bin:$PATH" bash "$D" >"$T/out" 2>&1
wait_for "run 54 to end" ended develop 54
wait_for "run 55 to end" ended develop 55
wait_for "lock 54 gone" lock_gone develop-54
wait_for "lock 55 gone" lock_gone develop-55
t "AC-1 cleanup_processes calls powershell.exe once per finished run" test "$(grep -c '^wt=' "$T/ps.calls")" = 2
t "AC-1 it targets only \$WT_ROOT/54/ (with the trailing slash, so 540 is not matched)" grep -qxF "wt=$FACTORY_WT_ROOT/54/" "$T/ps.calls"
t "AC-1 it targets only \$WT_ROOT/55/" grep -qxF "wt=$FACTORY_WT_ROOT/55/" "$T/ps.calls"
t "AC-1 nothing else is targeted (no bare \$WT_ROOT)" not grep -qxF "wt=$FACTORY_WT_ROOT" "$T/ps.calls"
t "AC-1 powershell runs non-interactive, without a profile" grep -q -- '-NoProfile -NonInteractive -Command' "$T/ps.calls"
t "AC-1 the script matches the command line of Win32_Process against the path" grep -q 'Win32_Process.*CommandLine -match' <<< "$(tr '\n' ' ' < "$T/ps.calls")"
t "AC-1 the script spares its own process" grep -q 'ProcessId -ne \$PID' "$T/ps.calls"
t "AC-1 cleanup runs while the run's lock still exists" grep -qx 'lock-present develop-54' "$T/ps.calls"
fresh; export Q_DEV=54
cat > "$T/bin/powershell.exe" <<'EOP'
#!/usr/bin/env bash
echo called >> "$T/ps.calls"
EOP
chmod +x "$T/bin/powershell.exe"
PATH="$T/bin:$PATH" bash "$D" >"$T/out" 2>&1  # FACTORY_CLEANUP=0 is the tests' default
wait_for "the run to end" ended develop 54
wait_for "lock gone" lock_gone develop-54
t "AC-1 FACTORY_CLEANUP=0 never calls powershell.exe" test ! -e "$T/ps.calls"
finish
