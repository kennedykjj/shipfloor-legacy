#!/usr/bin/env bash
# Stack lock with an owner and an expiry; acceptance-intact ignores files the QA commit deleted.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
export FACTORY_HOME="$(mktemp -d)"; L="$FACTORY_HOME/locks/stack.lock"
assert_exit 0 bash "$GATE" stack-lock acquire develop-28
assert_contains "$(cat "$L/info")" "develop-28"
assert_exit 1 env FACTORY_STACK_WAIT=1 bash "$GATE" stack-lock acquire develop-54
assert_exit 0 bash "$GATE" stack-lock release develop-54   # not the owner: no-op
[ -d "$L" ] && pass "other owner cannot release" || fail "released someone else's lock"
assert_exit 0 bash "$GATE" stack-lock release develop-28
[ ! -d "$L" ] && pass "owner released" || fail "lock left"
mkdir -p "$L"; echo "develop-28 $(( $(date +%s) - 4000 ))" > "$L/info"
assert_exit 0 env FACTORY_STACK_WAIT=1 bash "$GATE" stack-lock acquire develop-54
assert_contains "$(cat "$L/info")" "develop-54"

r="$(new_repo)"; cd "$r"; mkdir -p web/i18n web/e2e; echo old > web/i18n/index.test.ts; git add -A; git commit -qm base
git rm -q web/i18n/index.test.ts; echo new > web/e2e/i18n.spec.ts; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
finish
