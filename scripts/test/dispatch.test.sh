#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"
  export FACTORY_HOME="$(mktemp -d)" FACTORY_REPO="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  tmp="$(mktemp -d)"
  # fake board: answers from env vars Q_REF, Q_DEV, Q_PROD (first issue) and W_SR, W_CV (counts)
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
[ -n "${BOARD_FAIL:-}" ] && exit 1
case "$1 $2" in
  "count Spec Review") echo "${W_SR:-0}" ;;
  "count Coding") echo "${W_CV:-0}" ;;
  "eligible Ready for Refinement") echo "${Q_REF:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Ready for Prod") echo "${Q_PROD:-}" ;;
  "eligible "*) ;;
  *) echo 0 ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat) $*" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"
  export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
  printf '#!/usr/bin/env bash
echo "/sf:deploy $*" >> "%s/launched"
' "$tmp" > "$tmp/deploy"; chmod +x "$tmp/deploy"; export FACTORY_DEPLOY="$tmp/deploy"
  : > "$tmp/launched"
}
launched() { cat "$tmp/launched"; }

setup; export Q_REF=25 Q_DEV=40 Q_PROD=47 W_SR=0 W_CV=0
run_dispatch; out="$(launched)"
assert_contains "$out" "/sf:refine 25"; assert_contains "$out" "/sf:develop 40"; assert_contains "$out" "/sf:deploy 47"

setup; export Q_REF=25 W_SR=2 Q_DEV= Q_PROD=
run_dispatch; [ -z "$(launched)" ] && pass "spec review full → nothing" || fail "launched with full WIP"

setup; export Q_REF= Q_DEV=40 W_CV=4 Q_PROD=
run_dispatch; [ -z "$(launched)" ] && pass "coding+validation full → nothing" || fail "launched with full WIP"

setup; export Q_REF=25 W_SR=0 Q_DEV= Q_PROD=; mkdir -p "$FACTORY_HOME"; touch "$FACTORY_HOME/PAUSE"
run_dispatch; [ -z "$(launched)" ] && pass "PAUSE → nothing" || fail "ran while paused"

setup; export Q_REF=25 W_SR=0 Q_DEV= Q_PROD=
mkdir -p "$FACTORY_HOME/locks/refine-25.lock"; echo "1 $(date +%s) 26" > "$FACTORY_HOME/locks/refine-25.lock/info"
run_dispatch; [ -z "$(launched)" ] && pass "fresh lock respected" || fail "ignored fresh lock"

# an old lock whose process is gone: the pid of a process that already ended (pid 1 is alive, and root may signal it)
setup; export Q_REF=25 W_SR=0 Q_DEV= Q_PROD=; sh -c ':' & dead=$!; wait "$dead"
mkdir -p "$FACTORY_HOME/locks/refine-25.lock"; echo "$dead $(( $(date +%s) - 20000 )) 26" > "$FACTORY_HOME/locks/refine-25.lock/info"
run_dispatch; assert_contains "$(launched)" "/sf:refine 25"

setup; export Q_REF=25 W_SR=0 BOARD_FAIL=1
assert_exit 1 run_dispatch
[ -z "$(launched)" ] && pass "board failure → nothing" || fail "launched despite board failure"
[ ! -d "$FACTORY_HOME/locks/refine-25.lock" ] && pass "no lock left" || fail "left a lock"
unset BOARD_FAIL

# Working hours (~/.shipfloor/config.yml, hours): outside them nothing new starts. The clock is SHIPFLOOR_NOW, never the real time.
hours_cfg() { printf '%s\n' "$1" > "$SHIPFLOOR_HOME/config.yml"; }
starts_at() {  # starts_at <HH:MM>: one dispatcher cycle with all three queues full at that time; prints what it launched
  setup; export Q_REF=25 Q_DEV=40 Q_PROD=47 W_SR=0 W_CV=0 SHIPFLOOR_NOW="$1"
  run_dispatch >/dev/null 2>&1; launched
}
expect_runs() {  # expect_runs <test name> <HH:MM>
  local out; out="$(starts_at "$2")"
  case "$out" in *"/sf:refine 25"*"/sf:develop 40"*"/sf:deploy 47"*) pass "$1" ;; *) fail "$1: no runs started at $2: '$out'" ;; esac
}
expect_none() {  # expect_none <test name> <HH:MM>
  local out; out="$(starts_at "$2")"
  [ -z "$out" ] && pass "$1" || fail "$1: runs started at $2, outside the hours: $(printf '%s' "$out" | cut -c1-40 | head -3)"
}

# AC-1 outside the window nothing starts; the board is read, a finished run is reaped, a running session is left alone
hours_cfg 'hours: ["08:00-23:00"]'
setup; export Q_REF=25 Q_DEV=40 Q_PROD=47 W_SR=0 W_CV=0 SHIPFLOOR_NOW=23:30
printf 'stale\n' > "$FACTORY_HOME/board.tsv"
mkdir -p "$FACTORY_HOME/locks/develop-26.lock"; echo "$$ $(date +%s) 26" > "$FACTORY_HOME/locks/develop-26.lock/info"
mkdir -p "$FACTORY_HOME/locks/refine-31.lock"; echo "999999 $(( $(date +%s) - 20000 )) 31" > "$FACTORY_HOME/locks/refine-31.lock/info"
out="$(run_dispatch 2>&1)"; rc=$?
[ -z "$(launched)" ] && pass "AC-1 23:30 outside 08:00-23:00 starts no run" || fail "AC-1 runs started outside working hours: $(launched | cut -c1-40 | tr '\n' ' ')"
[ "$rc" = 0 ] && pass "AC-1 the cycle outside the hours ends with exit 0" || fail "AC-1 the cycle outside the hours ended with exit $rc: $out"
assert_contains "$out" "dispatch: outside working hours; runs start again at 08:00"
[ "$(cat "$FACTORY_HOME/board.tsv")" != "stale" ] && pass "AC-1 the board snapshot is refreshed outside the hours" || fail "AC-1 the board snapshot was not refreshed"
[ ! -d "$FACTORY_HOME/locks/refine-31.lock" ] && pass "AC-1 a finished run is reaped outside the hours" || fail "AC-1 the dead run's lock was not reaped"
[ -d "$FACTORY_HOME/locks/develop-26.lock" ] && pass "AC-1 a running session is left alone" || fail "AC-1 the running session's lock was removed"
unset SHIPFLOOR_NOW

# AC-2 the window includes its start and excludes its end
hours_cfg 'hours: ["08:00-23:00"]'
expect_runs "AC-2 08:00 is inside 08:00-23:00: runs start" 08:00
expect_none "AC-2 07:59 is before 08:00-23:00: nothing starts" 07:59
expect_runs "AC-2 22:59 is inside 08:00-23:00: runs start" 22:59
expect_none "AC-2 23:00 is the end of 08:00-23:00 and is outside: nothing starts" 23:00

# AC-3 a window that crosses midnight
hours_cfg 'hours: ["20:00-04:00"]'
expect_runs "AC-3 02:00 is inside 20:00-04:00: runs start" 02:00
expect_runs "AC-3 20:00 is inside 20:00-04:00: runs start" 20:00
expect_none "AC-3 12:00 is outside 20:00-04:00: nothing starts" 12:00
expect_none "AC-3 04:00 is the end of 20:00-04:00 and is outside: nothing starts" 04:00
hours_cfg 'hours: ["06:00-08:00", "20:00-23:00"]'
expect_runs "AC-3 with two windows, 21:00 is inside the second: runs start" 21:00
expect_none "AC-3 with two windows, 12:00 is between them: nothing starts" 12:00

# AC-8 hours unset (or empty): runs start at any time and the dispatcher says nothing about hours
rm -f "$SHIPFLOOR_HOME/config.yml"
expect_runs "AC-8 without hours, 03:00 starts runs" 03:00
expect_runs "AC-8 without hours, 23:30 starts runs" 23:30
setup; export Q_REF=25 Q_DEV=40 Q_PROD=47 W_SR=0 W_CV=0 SHIPFLOOR_NOW=23:30
out="$(run_dispatch 2>&1)"; case "$out" in *"working hours"*) fail "AC-8 the dispatcher spoke of working hours with none set: $out" ;; *) pass "AC-8 no working-hours line without hours" ;; esac
hours_cfg 'hours: []'
expect_runs "AC-8 an empty hours list is always: 23:30 starts runs" 23:30

# AC-5 a malformed hours does not stop the dispatcher: it reports hours and starts runs as always
hours_cfg 'hours: ["8-23"]'
expect_runs "AC-5 a malformed hours still starts runs at 23:30" 23:30
setup; export Q_REF=25 Q_DEV=40 Q_PROD=47 W_SR=0 W_CV=0 SHIPFLOOR_NOW=23:30
out="$(run_dispatch 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "AC-5 a malformed hours does not fail the cycle" || fail "AC-5 the cycle failed (exit $rc) because of a malformed hours: $out"
assert_contains "$out" "runs start at all hours"
hours_cfg 'hours: ["23:00-23:00"]'
expect_runs "AC-5 a window with start equal to end is malformed: runs start at 12:00" 12:00
unset SHIPFLOOR_NOW; rm -f "$SHIPFLOOR_HOME/config.yml"
finish
