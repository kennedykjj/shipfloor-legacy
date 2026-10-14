#!/usr/bin/env bash
# deploy.sh, the wrapper's contract through real processes (the behavior is in py/deploy_*.py, in process): usage,
# exit codes 0 / 2 / 3 / 5, what goes to stdout and stderr, argv passed through (--refresh, --continue), the lock
# between two runs, and the real gate.sh behind the fast gates.
source "$(dirname "$0")/deploy-lib.sh"
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out" "$T/err" 2>/dev/null)"; }

# usage: exit 2 and the usage line on stderr, nothing on stdout, gh never called
setup; code="$(run)"; want "$code" 2 "no argument → exit 2"
[ "$(cat "$T/err")" = "usage: deploy.sh <n> [--refresh | --continue]" ] && [ ! -s "$T/out" ] && pass "usage on stderr only" || fail "usage: $(cat "$T/out" "$T/err")"
code="$(run 7 --bogus)"; want "$code" 2 "unknown mode → exit 2"
[ ! -e "$FG/calls" ] && pass "usage errors: gh not called" || fail "gh called: $(cat "$FG/calls")"

# the happy path to Done: exit 0, the log on stdout, the card in Done, the real gate ran
setup; code="$(run 7)"; want "$code" 0 "a staged card deploys → exit 0"
[ "$(cat "$FG/status")" = Done ] && pass "card in Done" || fail "status $(cat "$FG/status")"
grep -q '^deploy #7: done in [0-9]* min$' "$T/out" && pass "the log goes to stdout, 'deploy #7: ...' lines" || fail "stdout: $(cat "$T/out")"
grep -q 'Deployed: merge' "$FG/comments" && pass "the Deployed comment" || fail "comments: $(cat "$FG/comments")"

# blocked by the real fast gates (a forbidden path): exit 5, gate.sh's output kept in gates.txt
setup; on_branch docs/engineering/a.md x; code="$(run 7)"; want "$code" 5 "a forbidden path → blocked, exit 5"
grep -q 'forbidden' "$FACTORY_HOME/tmp/7/gates.txt" && pass "gate.sh's output in gates.txt" || fail "gates.txt: $(cat "$FACTORY_HOME/tmp/7/gates.txt")"
grep -q 'blocked: gates failed: ' "$T/out" && pass "blocked: the reason in the log" || fail "stdout: $(cat "$T/out")"

# a conflict handed over (exit 3), then --continue passed through to the resolution check (exit 0)
setup; on_branch shared.txt card; main_commit shared.txt main; code="$(run 7)"; want "$code" 3 "a conflict → handed over, exit 3"
grep -qx 'CONFLICT shared.txt' "$T/out" && pass "CONFLICT lines on stdout" || fail "stdout: $(cat "$T/out")"
w="$FACTORY_WT_ROOT/7"; echo resolved > "$w/shared.txt"; git -C "$w" add shared.txt; git -C "$w" -c user.email=t@t -c user.name=t commit -q --no-edit
code="$(run 7 --continue)"; want "$code" 0 "--continue after the resolution → exit 0"

# --refresh passed through: a card in Ready for Prod is not refreshed (exit 0)
setup; code="$(run 7 --refresh)"; want "$code" 0 "--refresh on a card not Staged → exit 0"
grep -q 'nothing to refresh' "$T/out" && pass "--refresh reached the deploy" || fail "stdout: $(cat "$T/out")"

# the lock between two real runs: a second deploy.sh on the same card while the first waits → exit 2
setup; printf '#!/usr/bin/env bash\ncase "$1" in status) touch "%s/in-board"; while [ ! -e "%s/go" ]; do sleep 0.05; done; cat "%s/status" ;; move) echo "$3" > "%s/status" ;; esac\n' "$FG" "$FG" "$FG" "$FG" > "$T/board"
(cd "$repo" && bash "$DEP" 7 > "$T/out1" 2>&1; echo $? > "$T/rc1") &
wait_for "the first run to hold the lock" test -e "$FG/in-board"
code="$(run 7)"; want "$code" 2 "a second run on a busy card → exit 2"
grep -q 'another deploy.sh runs on this card (pid ' "$T/out" && pass "the second run names the holder" || fail "stdout: $(cat "$T/out")"
touch "$FG/go"; wait
[ "$(cat "$T/rc1")" = 0 ] && pass "the first run goes on and deploys" || fail "first run: $(cat "$T/rc1"): $(cat "$T/out1")"
[ ! -e "$FACTORY_HOME/locks/deploysh-7.lock" ] && pass "the lock goes with the run" || fail "lock left"
finish
