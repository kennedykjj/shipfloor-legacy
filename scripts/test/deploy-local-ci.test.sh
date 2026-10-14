#!/usr/bin/env bash
# deploy.local_ci: a project with no CI on GitHub has the deploy run its own command on the head merged with main,
# where it would wait for GitHub's checks.
source "$(dirname "$0")/deploy-lib.sh"
lci() { sed -i '/^deploy:/d' "$FACTORY_CONFIG"; printf "deploy: {local_ci: '%s'}\n" "$1" >> "$FACTORY_CONFIG"; }

# green: the command runs in the card's worktree on the head that has main in it, and the card ships;
# GitHub's checks are red here and are not asked for
scene behind; echo "api=FAILURE" > "$FG/ci"; lci 'git rev-parse HEAD > "$FG/ran"; test -f web/other.ts && test -f api/A.kt'
code="$(run 7)"; [ "$code" = 0 ] && pass "green local CI ships the card" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = Done ] && pass "card in Done" || fail "status $(cat "$FG/status")"
[ -s "$FG/ran" ] && pass "the command ran" || fail "the command did not run"
git --git-dir="$remote" merge-base --is-ancestor "$(git --git-dir="$remote" rev-parse main~1)" "$(cat "$FG/ran")" 2>/dev/null \
  && pass "it ran on a head that contains main" || fail "it ran on $(cat "$FG/ran"), without main"
case "$(cat "$FG/calls")" in *statusCheckRollup*) fail "asked GitHub for checks with local_ci set" ;; *) pass "GitHub's checks are not asked for" ;; esac
assert_contains "$(cat "$T/out")" "local CI passed on"

# red after merging main: a fix round, with the command and the end of its output as the findings
scene behind; lci 'echo "suite: 3 FAIL in gate.test.sh"; exit 1'
code="$(run 7)"; [ "$code" = 3 ] && pass "red local CI hands the card to a fix round" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FACTORY_HOME/tmp/7/fix.findings")" "suite: 3 FAIL in gate.test.sh"
assert_contains "$(cat "$FACTORY_HOME/tmp/7/fix.findings")" "deploy.local_ci:"
[ "$(cat "$FG/status")" != Done ] && pass "a red card did not ship" || fail "shipped a red card"
git --git-dir="$remote" show main:api/A.kt >/dev/null 2>&1 && fail "merged a red card" || pass "nothing merged"

# red on the head the owner approved, with nothing merged in: blocked for the owner, not shipped
setup; lci 'exit 1'
code="$(run 7)"; [ "$code" != 0 ] && [ "$code" != 3 ] && pass "red on the approved head blocks (exit $code)" || fail "exit $code: $(cat "$T/out")"
git --git-dir="$remote" show main:api/A.kt >/dev/null 2>&1 && fail "merged a red card" || pass "nothing merged"

# without local_ci nothing changes: the deploy waits for GitHub's checks
setup; code="$(run 7)"; [ "$code" = 0 ] && pass "no local_ci: deploys on GitHub's checks" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/calls")" "statusCheckRollup"

# AC-10: without GNU timeout on the PATH (macOS), a local CI that hangs is still stopped at deploy.timeout_min
nt="$(mktemp -d)"
IFS=: read -r -a pdirs <<< "$PATH"
for pd in "${pdirs[@]}"; do
  for f in "$pd"/*; do
    b="${f##*/}"; case "$b" in timeout|gtimeout) continue ;; esac
    [ -x "$f" ] && [ ! -e "$nt/$b" ] && ln -s "$f" "$nt/$b"
  done
done
PATH="$nt" command -v timeout >/dev/null 2>&1 && fail "the PATH for AC-10 still has timeout" || pass "AC-10 the test PATH has no timeout"
setup; sed -i '/^deploy:/d' "$FACTORY_CONFIG"; printf "deploy: {timeout_min: 1, local_ci: 'sleep 75'}\n" >> "$FACTORY_CONFIG"
t0=$SECONDS; code="$(PATH="$nt" run 7)"; took=$(( SECONDS - t0 ))
[ "$code" != 0 ] && pass "AC-10 a local CI that hangs does not ship the card (exit $code)" || fail "AC-10 the hanging CI passed: $(cat "$T/out")"
[ "$took" -lt 72 ] && pass "AC-10 it was stopped at its limit, not left to run (${took}s)" || fail "AC-10 the hanging CI ran ${took}s past its 60 s limit"
assert_contains "$(cat "$T/out")" "local CI did not finish"
[ "$(cat "$FG/status")" != Done ] && pass "AC-10 the card did not ship" || fail "AC-10 shipped with a CI that never finished"
finish
