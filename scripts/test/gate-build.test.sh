#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
bin="$(mktemp -d)"

fake() {  # fake <name> <exit> <output>
  printf '#!/usr/bin/env bash\necho "$0 $*" >> "%s/calls"\nprintf "%%s\n" "%s"\nexit %s\n' "$bin" "$3" "$2" > "$bin/$1"
  chmod +x "$bin/$1"
}

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p api web; echo x > api/A.kt
fake mvn 0 "BUILD SUCCESS"; fake pnpm 0 "ok"; : > "$bin/calls"
assert_exit 0 env FACTORY_MVN="$bin/mvn" FACTORY_PNPM="$bin/pnpm" bash "$GATE" build "$base"
assert_contains "$(cat "$bin/calls")" "mvn -q test"
case "$(cat "$bin/calls")" in *pnpm*) fail "pnpm ran without web changes" ;; *) pass "pnpm skipped" ;; esac

fake mvn 1 "Tests run: 3, Failures: 1"
assert_exit 1 env FACTORY_MVN="$bin/mvn" FACTORY_PNPM="$bin/pnpm" bash "$GATE" build "$base"

# red: assertion failure passes the gate
fake mvn 1 "org.opentest4j.AssertionFailedError: expected: <429> but was: <200>"
assert_exit 0 env FACTORY_MVN="$bin/mvn" bash "$GATE" red api RateLimitFilterTest
# red: compile error does not
fake mvn 1 "[ERROR] COMPILATION ERROR : unresolved reference: Foo"
assert_exit 1 env FACTORY_MVN="$bin/mvn" bash "$GATE" red api RateLimitFilterTest
# red: green tests do not
fake mvn 0 "BUILD SUCCESS"
assert_exit 1 env FACTORY_MVN="$bin/mvn" bash "$GATE" red api RateLimitFilterTest
# red web: vitest assertion
fake pnpm 1 "AssertionError: expected 'a' to be 'b'"
assert_exit 0 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web lib/a.test.ts
fake pnpm 1 "Error: Cannot find module './missing'"
assert_exit 1 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web lib/a.test.ts
finish
