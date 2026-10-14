#!/usr/bin/env bash
# inbox-hook.sh (#161, PY-08): the PostToolUse hook costs nothing when the owner sent nothing: it exits 0 and never starts Python.
source "$(dirname "$0")/lib.sh"
HOOK="$FACTORY_DIR/inbox-hook.sh"
unset SHIPFLOOR_PY SHIPFLOOR_RUN_LOCK

# a stand-in for Python that records that it was started
d="$(mktemp -d)"; calls="$d/python-calls"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$calls" > "$d/python"; chmod +x "$d/python"
export FACTORY_PYTHON="$d/python"
started() { [ -s "$calls" ]; }
check_quiet() {  # check_quiet <what>: the hook ran, Python did not
  if started; then fail "AC-7 $1: FACTORY_PYTHON was invoked: $(cat "$calls")"; : > "$calls"; else pass "AC-7 $1: FACTORY_PYTHON was not invoked"; fi
}

# no lock at all
assert_exit 0 bash "$HOOK"; check_quiet "no lock"
# a lock with no inbox file
lock="$(mktemp -d)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$HOOK"; check_quiet "a lock and no inbox file"
# an empty inbox file is no message either
: > "$lock/inbox"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$HOOK"; check_quiet "an empty inbox file"
# a lock folder that does not exist
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$d/no-such-lock" bash "$HOOK"; check_quiet "a missing lock folder"
# nothing printed either
[ -z "$(env SHIPFLOOR_RUN_LOCK="$lock" bash "$HOOK" 2>&1)" ] && pass "AC-7 no inbox: no output" || fail "AC-7 no inbox, but the hook printed something"

# the check is not vacuous: with a message in the inbox the same stand-in is started, with inbox_hook.py
echo "hello" > "$lock/inbox"
env SHIPFLOOR_RUN_LOCK="$lock" bash "$HOOK" >/dev/null 2>&1
started && pass "AC-7 precondition: a non-empty inbox starts Python" || fail "AC-7 precondition: a non-empty inbox did not start Python"
assert_contains "$(cat "$calls" 2>/dev/null)" "inbox_hook.py"
finish
