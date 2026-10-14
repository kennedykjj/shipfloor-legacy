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
# a gate says its verdict last, on stderr: no caller needs `; echo $?`, and stdout stays what callers read
assert_contains "$(env FACTORY_MVN="$bin/mvn" FACTORY_PNPM="$bin/pnpm" bash "$GATE" build "$base" 2>&1 >/dev/null | tail -1)" "gate build: FAIL (exit 1)"
fake mvn 0 "BUILD SUCCESS"
assert_contains "$(env FACTORY_MVN="$bin/mvn" FACTORY_PNPM="$bin/pnpm" bash "$GATE" build "$base" 2>&1 >/dev/null | tail -1)" "gate build: pass"
assert_exit 0 bash "$GATE" --help
assert_contains "$(bash "$GATE" --help)" "green <layer> <selector>"
assert_exit 2 bash "$GATE" nonsense
assert_exit 0 bash "$FACTORY_DIR/report.sh" --help

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
# ---- what red and green print (pinned when gate-py-run-diff.test.sh compared them with the Bash gate)
lines() { local i; for i in $(seq 1 "$2"); do echo "$1 $i"; done; }   # lines <text> <n>
outfake() {  # outfake <name> <exit> <file>: prints the file, logs its argument count and its last argument
  printf '#!/usr/bin/env bash\necho "$# ${@: -1}" >> "%s/args"\ncat "%s"\nexit %s\n' "$bin" "$3" "$2" > "$bin/$1"; chmod +x "$bin/$1"
}
r="$(new_repo)"; cd "$r"; mkdir -p api web
{ echo "[INFO] running"; lines "org.opentest4j.AssertionFailedError: expected: <429> but was: <200> at" 25; echo "[INFO] done"; } > "$bin/red.out"
outfake mvn 1 "$bin/red.out"
out="$(FACTORY_MVN="$bin/mvn" bash "$GATE" red api RateLimitFilterTest 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c AssertionFailedError <<< "$out")" = 20 ] && [ "$(grep -vc AssertionFailedError <<< "$out")" = 0 ] \
  && pass "red prints the assertion lines, 20 at most, and nothing else" || fail "red stdout (exit $rc): $out"
{ lines "src/a.ts: error TS2304: Cannot find name" 7; echo "AssertionError: expected 1 to be 2"; } > "$bin/setup.out"
outfake pnpm 1 "$bin/setup.out"
err="$(FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web lib/a.test.ts 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] && [ "$err" = "red: tests fail for setup/compile reasons, not behavior:
$(lines "src/a.ts: error TS2304: Cannot find name" 5)
gate red: FAIL (exit 1)" ] && pass "red blocks on setup errors and shows the first 5 of them" || fail "red setup errors (exit $rc): $err"
echo "AssertionError: expected 'a' to be 'b'" > "$bin/ok.out"; outfake pnpm 1 "$bin/ok.out"; : > "$bin/args"
sel='a b;$(touch pwned) "q"'
assert_exit 0 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web "$sel"
[ ! -e pwned ] && [ "$(cat "$bin/args")" = "4 $sel" ] && pass "red hands the selector to the runner as one argument, never as shell code" || fail "selector: $(cat "$bin/args"), pwned: $(ls pwned 2>&1)"
lines "failing line" 30 > "$bin/green.out"; outfake pnpm 1 "$bin/green.out"
err="$(FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web web/a.test.ts 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] && [ "$err" = "green: acceptance tests fail:
$(lines "failing line" 30 | tail -20)
gate green: FAIL (exit 1)" ] && pass "green shows the last 20 lines of a failing run" || fail "green failure (exit $rc): $err"
err="$(FACTORY_LANGUAGE=pt-BR FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web web/a.test.ts 2>&1 >/dev/null)"
case "$err" in "green: os testes de aceitação falham:"*"gate green: FAIL (exit 1)") pass "green says it in the project's language, the verdict in English" ;; *) fail "green in pt-BR: $err" ;; esac
r="$(new_repo)"; cd "$r"; mkdir -p api
err="$(FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web x 2>&1)"; rc=$?
[ "$rc" = 1 ] && assert_contains "$err" "gate: layer directory web/ not found" || fail "a missing layer directory: exit $rc: $err"
badpat="$(mktemp)"; sed "s/^    ran: 'Tests +\[1-9\]\[0-9\]\* passed'$/    ran: 'a('/" "$FACTORY_DIR/test/fixture/factory.yml" > "$badpat"
grep -q "ran: 'a('" "$badpat" && assert_exit 2 env FACTORY_CONFIG="$badpat" FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web x || fail "could not build the bad-pattern config"
finish
