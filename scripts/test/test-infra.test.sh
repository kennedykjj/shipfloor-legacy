#!/usr/bin/env bash
# The test infrastructure itself: run.sh --changed picks the tests tied to what changed (and every test when a shared
# helper changes), run.sh removes the temp dirs of its tests even when killed, lib.sh's wait_for is bounded, and the
# in-process runner (py/run.py, py/support.py) checked by py/selftest_support.py.
source "$(dirname "$0")/lib.sh"

# ---- run.sh --changed: a changed test file, or a test that names a changed script; a shared helper runs everything
r="$(new_repo)"; cd "$r"; mkdir -p scripts/test; cp "$FACTORY_DIR/test/run.sh" scripts/test/
echo 'echo x' > scripts/x.sh; echo 'echo y' > scripts/y.sh; echo '# helper' > scripts/test/lib.sh
printf '#!/usr/bin/env bash\n# uses x.sh\necho "  ok   a"\n' > scripts/test/a.test.sh
printf '#!/usr/bin/env bash\n# uses y.sh\necho "  ok   b"\n' > scripts/test/b.test.sh
git add -A; git commit -qm base; git branch -q base
ran() { bash scripts/test/run.sh --changed base 2>&1; }

assert_contains "$(ran)" "nothing to run"
echo 'echo x2' > scripts/x.sh
out="$(ran)"; assert_contains "$out" "== a.test.sh"
case "$out" in *"== b.test.sh"*) fail "ran a test of an unchanged script" ;; *) pass "only the affected test ran" ;; esac
git commit -qam x; echo '# new' >> scripts/test/b.test.sh
out="$(ran)"; assert_contains "$out" "== a.test.sh"; assert_contains "$out" "== b.test.sh"
git checkout -q -- scripts/test/b.test.sh; echo '# changed' >> scripts/test/lib.sh
assert_contains "$(ran)" "== 2 files"
# the temp dirs a test makes go with the run, also when the run is killed
printf '#!/usr/bin/env bash\nd="$(mktemp -d)"; touch "$d/f"; echo "$d" > "%s/made"; echo "  ok   c"\n' "$r" > scripts/test/c.test.sh
bash scripts/test/run.sh c.test.sh >/dev/null 2>&1
made="$(cat "$r/made")"; [ -n "$made" ] && [ ! -e "$made" ] && pass "a test's temp dir is gone after the run" || fail "left behind: $made"
printf '#!/usr/bin/env bash\nd="$(mktemp -d)"; echo "$d" > "%s/made"; sleep 30\n' "$r" > scripts/test/c.test.sh
bash scripts/test/run.sh c.test.sh >/dev/null 2>&1 & pid=$!
for _ in $(seq 1 50); do [ -s "$r/made" ] && [ "$(cat "$r/made")" != "$made" ] && break; sleep 0.1; done
kill -TERM "$pid"; wait "$pid" 2>/dev/null
made="$(cat "$r/made")"; [ ! -e "$made" ] && pass "a killed run removes its temp dirs" || fail "a killed run left: $made"
pkill -f "$r/made" 2>/dev/null

# ---- wait_for <what> <command...>: polls every 0.1 s, bounded by TEST_WAIT_SECS seconds (default 60)
tmp="$(mktemp -d)"
wait_for "a true command" true; rc=$?
[ "$rc" -eq 0 ] && pass "wait_for returns 0 when the command succeeds" || fail "wait_for returned $rc for a command that succeeds"
( sleep 0.5; touch "$tmp/late" ) &
wait_for "a file to appear" test -e "$tmp/late"; rc=$?
[ "$rc" -eq 0 ] && pass "wait_for waits until the command succeeds" || fail "wait_for returned $rc although the file appeared"
wait
start=$SECONDS
out="$( TEST_WAIT_SECS=1; wait_for "the run to end" test -e "$tmp/never" 2>&1 )"; rc=$?
elapsed=$((SECONDS - start))
assert_contains "$out" "FAIL timed out waiting for the run to end"
[ "$rc" -eq 1 ] && pass "wait_for returns 1 on timeout" || fail "wait_for returned $rc on timeout, want 1"
[ "$elapsed" -le 10 ] && [ "$elapsed" -ge 1 ] && pass "wait_for waits the bound, and only the bound (${elapsed}s with TEST_WAIT_SECS=1)" || fail "wait_for took ${elapsed}s with TEST_WAIT_SECS=1"
rm -rf "$tmp"

py_suite selftest_support
finish
