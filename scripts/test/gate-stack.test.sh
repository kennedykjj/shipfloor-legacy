#!/usr/bin/env bash
# e2e runs share one local stack: they queue on the project home/locks/stack.lock.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"
printf '#!/usr/bin/env bash\n[ -d "%s/locks/stack.lock" ] && echo held >> "%s/seen"\necho "  2 passed (1.0s)"\n' "$FACTORY_HOME" "$bin" > "$bin/pnpm"; chmod +x "$bin/pnpm"
r="$(new_repo)"; cd "$r"; mkdir -p web
assert_exit 0 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" green e2e e2e/a.spec.ts
assert_contains "$(cat "$bin/seen" 2>/dev/null)" "held"
[ ! -d "$FACTORY_HOME/locks/stack.lock" ] && pass "stack lock released" || fail "stack lock left behind"
mkdir -p "$FACTORY_HOME/locks/stack.lock"; echo "$$ $(date +%s) 99" > "$FACTORY_HOME/locks/stack.lock/info"
assert_exit 1 env FACTORY_PNPM="$bin/pnpm" FACTORY_STACK_WAIT=1 bash "$GATE" green e2e e2e/a.spec.ts
finish
