#!/usr/bin/env bash
# shipfloor-config.sh (#161, PY-08): `step <k>`, the skill step a run records for the dashboard. It never fails a run.
source "$(dirname "$0")/lib.sh"
CFG="$FACTORY_DIR/shipfloor-config.sh"
unset SHIPFLOOR_RUN_LOCK

# with a lock folder: k<TAB><epoch seconds> in <lock>/step, exit 0
lock="$(mktemp -d)"
t0="$(date +%s)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step 3
t1="$(date +%s)"
IFS=$'\t' read -r k ts rest < "$lock/step"
[ "$k" = 3 ] && pass "AC-6 step 3 writes k in the first column" || fail "AC-6 first column: '$k'"
case "$ts" in ''|*[!0-9]*) fail "AC-6 second column is not an epoch: '$ts'" ;; *) [ "$ts" -ge "$t0" ] && [ "$ts" -le "$t1" ] && pass "AC-6 the second column is the epoch of the call" || fail "AC-6 epoch $ts outside $t0..$t1" ;; esac
[ -z "$rest" ] && pass "AC-6 the line has two columns" || fail "AC-6 extra columns: $rest"
[ "$(grep -c . "$lock/step")" = 1 ] && [ "$(wc -l < "$lock/step" | tr -d ' ')" = 1 ] && pass "AC-6 one newline-ended line" || fail "AC-6 step file: $(od -c "$lock/step" | head -3)"
# a later step replaces the earlier one
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step 12
IFS=$'\t' read -r k ts < "$lock/step"
[ "$k" = 12 ] && [ "$(grep -c . "$lock/step")" = 1 ] && pass "AC-6 a later step replaces the earlier one" || fail "AC-6 step file after 12: $(cat "$lock/step")"

# a non-numeric k, or none: nothing is written (the earlier line stays) and the exit code is 0
before="$(cat "$lock/step")"
for bad in x 3a -1 1.5 "" "1 2"; do
  assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step "$bad"
done
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step
[ "$(cat "$lock/step")" = "$before" ] && pass "AC-6 a non-numeric or missing k writes nothing" || fail "AC-6 step file changed to: $(cat "$lock/step")"
lock2="$(mktemp -d)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock2" bash "$CFG" step abc
[ ! -e "$lock2/step" ] && pass "AC-6 a non-numeric k creates no step file" || fail "AC-6 step file for abc: $(cat "$lock2/step")"

# no lock: exit 0, nothing written. The lock variable empty, or naming a folder that does not exist: the same
assert_exit 0 bash "$CFG" step 5
assert_exit 0 env SHIPFLOOR_RUN_LOCK= bash "$CFG" step 5
gone="$(mktemp -d)/no-such-lock"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$gone" bash "$CFG" step 5
[ ! -e "$gone" ] && pass "AC-6 a missing lock folder is not created" || fail "AC-6 created $gone"
# nor does step 5 land in the current folder
cwd="$(mktemp -d)"; ( cd "$cwd" && bash "$CFG" step 5 ); [ -z "$(find "$cwd" -mindepth 1 -print -quit)" ] && pass "AC-6 no lock: nothing is written anywhere" || fail "AC-6 no lock, but a file appeared in $cwd"
# a lock that is a file, not a folder, is no lock
file="$(mktemp)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$file" bash "$CFG" step 5
[ ! -s "$file" ] && pass "AC-6 a lock that is a file is left alone" || fail "AC-6 wrote into a file lock"
# step needs no project: it runs where no config resolves
assert_exit 0 env -u FACTORY_CONFIG SHIPFLOOR_HOME="$(mktemp -d)" SHIPFLOOR_RUN_LOCK="$lock2" bash "$CFG" step 7
[ "$(cut -f1 "$lock2/step")" = 7 ] && pass "AC-6 step works with no project config" || fail "AC-6 step without a config: $(cat "$lock2/step" 2>/dev/null)"
finish
