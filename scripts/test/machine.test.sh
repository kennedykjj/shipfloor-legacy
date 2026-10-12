#!/usr/bin/env bash
# ~/.shipfloor/config.yml: the machine-wide agent pool and the runs each stage may take.
source "$(dirname "$0")/lib.sh"
export SHIPFLOOR_HOME="$(mktemp -d)"
m() { bash -c "source '$FACTORY_DIR/lib/project.sh'; shipfloor_machine \"\$@\"" _ "$@"; }
vals() { m values pool stages.refine stages.develop stages.validate stages.deploy | tr '\0' ' '; }

[ "$(vals)" = "4 2 2 2 1 " ] && pass "defaults without a file" || fail "defaults: $(vals)"
assert_exit 0 m validate

printf 'pool: 6\nstages: {develop: 3}\n' > "$SHIPFLOOR_HOME/config.yml"
[ "$(vals)" = "6 2 3 2 1 " ] && pass "values merged with defaults" || fail "values: $(vals)"

bad() { printf '%s\n' "$1" > "$SHIPFLOOR_HOME/config.yml"; assert_exit 1 m validate; }
bad 'pool: 0'
bad 'pool: two'
bad $'pool: 2\nstages: {develop: 3}'
bad $'pool: 4\nstages: {review: 1}'
bad $'pool: 4\nstages: {refine: -1}'
bad 'stages: 3'
bad '[unclosed'
assert_exit 2 m values pool   # an unusable machine config is never read as a limit

printf '# my machine\npool: 4\nstages: {refine: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
assert_exit 0 m set pool 6
assert_exit 0 m set stages.validate 3
[ "$(vals)" = "6 1 2 3 1 " ] && pass "set keeps the other values" || fail "after set: $(vals)"
assert_exit 1 m set stages.validate 9      # above the pool
assert_exit 1 m set stages.review 1       # unknown stage
assert_exit 1 m set pool x
[ "$(vals)" = "6 1 2 3 1 " ] && pass "rejected sets change nothing" || fail "changed by a rejected set: $(vals)"
# stack slots and their timers have defaults and are validated like the pool
rm -f "$SHIPFLOOR_HOME/config.yml"
assert_contains "$(m values stacks ports.base ports.span stack_wait stack_stale stack_hold_max | tr '\0' ' ')" "3 20000 20 1800 90 2700"
bad 'stacks: 0'
bad 'ports: {base: 70000, span: 20}'
bad 'stack_wait: x'

# working hours: `machine hours` says open, or closed and when the next window starts; the clock is SHIPFLOOR_NOW
hoursat() { SHIPFLOOR_NOW="$1" m hours 2>&1 | tr -d '\r'; }
expect() {  # expect <test name> <HH:MM> <want>
  local got; got="$(hoursat "$2")"
  [ "$got" = "$3" ] && pass "$1" || fail "$1: at $2 'machine hours' printed '$got', want '$3'"
}
printf 'hours: ["08:00-23:00"]\n' > "$SHIPFLOOR_HOME/config.yml"
expect "AC-1 closed after the window, next start 08:00" 23:30 "closed 08:00"
expect "AC-2 the window includes its start" 08:00 "open"
expect "AC-2 the window excludes its end" 23:00 "closed 08:00"
expect "AC-2 one minute before the start is closed" 07:59 "closed 08:00"
expect "AC-2 inside the window is open" 12:00 "open"
export SHIPFLOOR_NOW=23:30; assert_exit 0 m hours; unset SHIPFLOOR_NOW  # closed or open, it exits 0
printf 'hours: ["20:00-04:00"]\n' > "$SHIPFLOOR_HOME/config.yml"
expect "AC-3 a window across midnight is open at 02:00" 02:00 "open"
expect "AC-3 across midnight, open at 23:59" 23:59 "open"
expect "AC-3 across midnight, closed at its end 04:00" 04:00 "closed 20:00"
expect "AC-3 across midnight, closed at noon" 12:00 "closed 20:00"
printf 'hours: ["06:00-08:00", "20:00-23:00"]\n' > "$SHIPFLOOR_HOME/config.yml"
expect "two windows: the next start between them is the second" 12:00 "closed 20:00"
expect "two windows: after the last, the next start is the first, tomorrow" 23:30 "closed 06:00"
expect "two windows: inside the first" 07:00 "open"
printf 'hours: ["00:00-23:59"]\n' > "$SHIPFLOOR_HOME/config.yml"
expect "00:00-23:59 are valid bounds" 12:00 "open"
printf 'hours: []\n' > "$SHIPFLOOR_HOME/config.yml"
expect "AC-8 an empty list is always open" 03:00 "open"
rm -f "$SHIPFLOOR_HOME/config.yml"
expect "AC-8 without hours it is always open" 03:00 "open"

# AC-5 a malformed hours is reported by name and ignored: validate still exits 0, the machine is open at all hours
for badh in 'hours: "08:00-23:00"' 'hours: ["8-23"]' 'hours: ["08:00-08:00"]' 'hours: ["24:00-25:00"]' 'hours: ["08:00-23:60"]' 'hours: ["08:00-23:00", 5]' 'hours: 8'; do
  printf '%s\n' "$badh" > "$SHIPFLOOR_HOME/config.yml"
  out="$(m validate 2>&1)"; rc=$?
  [ "$rc" = 0 ] && pass "AC-5 validate exits 0 when hours is the only problem ($badh)" || fail "AC-5 validate exited $rc for '$badh': $out"
  case "$out" in *"hours"*"ignored, runs start at all hours"*) pass "AC-5 the report names hours ($badh)" ;; *) fail "AC-5 validate does not name hours for '$badh': '$out'" ;; esac
  expect "AC-5 malformed ($badh) reads as open" 23:30 "open"
  assert_exit 0 m hours
done
printf 'pool: 6\nhours: ["8-23"]\n' > "$SHIPFLOOR_HOME/config.yml"
[ "$(vals)" = "6 2 2 2 1 " ] && pass "AC-5 a malformed hours does not make the other values unusable" || fail "AC-5 values with a malformed hours: '$(vals)'"
printf 'pool: 0\nhours: ["8-23"]\n' > "$SHIPFLOOR_HOME/config.yml"
out="$(m validate 2>&1)"; rc=$?
[ "$rc" = 1 ] && pass "AC-5 another problem next to a bad hours still exits 1" || fail "AC-5 validate exited $rc with pool: 0 and a bad hours: $out"
# the dispatcher's pace: 1, 3, 5 or 10 minutes, 3 when missing; anything else is a machine problem naming the key and the values
rm -f "$SHIPFLOOR_HOME/config.yml"
[ "$(m values dispatcher.every_min | tr '\0' ' ')" = "3 " ] && pass "AC-5 dispatcher.every_min defaults to 3" || fail "AC-5 default every_min: $(m values dispatcher.every_min | tr '\0' ' ')"
for v in 1 3 5 10; do
  printf 'dispatcher: {every_min: %s}\n' "$v" > "$SHIPFLOOR_HOME/config.yml"
  assert_exit 0 m validate
  [ "$(m values dispatcher.every_min | tr '\0' ' ')" = "$v " ] && pass "AC-5 every_min $v is read back" || fail "AC-5 every_min $v read as: $(m values dispatcher.every_min | tr '\0' ' ')"
done
for v in 0 2 7 15 true '"5"' 3.5; do
  printf 'dispatcher: {every_min: %s}\n' "$v" > "$SHIPFLOOR_HOME/config.yml"
  out="$(m validate 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && pass "AC-5 every_min $v is a machine problem" || fail "AC-5 every_min $v validated (exit $rc): $out"
  case "$out" in *"dispatcher.every_min must be 1, 3, 5 or 10"*) pass "AC-5 every_min $v names the key and the allowed values" ;; *) fail "AC-5 every_min $v: message was '$out' (want 'dispatcher.every_min must be 1, 3, 5 or 10')" ;; esac
done
printf 'dispatcher: 5\n' > "$SHIPFLOOR_HOME/config.yml"
out="$(m validate 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "AC-5 dispatcher that is not a mapping is a machine problem" || fail "AC-5 dispatcher: 5 validated (exit $rc): $out"
case "$out" in *"dispatcher must be a mapping"*) pass "AC-5 dispatcher: 5 says it must be a mapping" ;; *) fail "AC-5 dispatcher: 5 message was '$out' (want 'dispatcher must be a mapping')" ;; esac
rm -f "$SHIPFLOOR_HOME/config.yml"
finish
