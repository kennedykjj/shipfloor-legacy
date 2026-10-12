#!/usr/bin/env bash
# wait_for <what> <command...>: polls every 0.1 s, bounded by TEST_WAIT_SECS seconds (default 60).
source "$(dirname "$0")/lib.sh"

if ! type wait_for >/dev/null 2>&1; then
  fail "AC-4 expected lib.sh to offer a bounded wait (wait_for <what> <command...>) that fails after TEST_WAIT_SECS naming what it waited for, and it offers none"
  finish; exit
fi

tmp="$(mktemp -d)"

# returns 0 at once when the command already succeeds
wait_for "a true command" true; rc=$?
[ "$rc" -eq 0 ] && pass "wait_for returns 0 when the command succeeds" || fail "wait_for returned $rc for a command that succeeds"

# passes its arguments to the command and waits until it succeeds
( sleep 0.5; touch "$tmp/late" ) &
wait_for "a file to appear" test -e "$tmp/late"; rc=$?
[ "$rc" -eq 0 ] && pass "wait_for waits until the command succeeds" || fail "wait_for returned $rc although the file appeared"
wait

# AC-4: a condition that never holds fails within a bounded time, naming what it waited for
start=$SECONDS
out="$( TEST_WAIT_SECS=1; wait_for "the run to end" test -e "$tmp/never" 2>&1 )"; rc=$?
elapsed=$((SECONDS - start))
assert_contains "$out" "FAIL timed out waiting for the run to end"
[ "$rc" -eq 1 ] && pass "AC-4 wait_for returns 1 on timeout" || fail "AC-4 wait_for returned $rc on timeout, want 1"
[ "$elapsed" -le 10 ] && pass "AC-4 wait_for is bounded (${elapsed}s with TEST_WAIT_SECS=1)" || fail "AC-4 wait_for took ${elapsed}s with TEST_WAIT_SECS=1"
[ "$elapsed" -ge 1 ] && pass "AC-4 wait_for waited the bound before failing" || fail "AC-4 wait_for gave up after ${elapsed}s, before TEST_WAIT_SECS=1"

rm -rf "$tmp"
finish
