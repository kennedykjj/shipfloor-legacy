#!/usr/bin/env bash
# deploy.sh happy paths and failures after merge: Done, merge of main, red CI, health check revert, resume.
source "$(dirname "$0")/deploy-lib.sh"

# up to date head: merged, health checked, Done
setup; code="$(run 7)"; [ "$code" = 0 ] && pass "deploy done" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = Done ] && pass "card in Done" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "Deployed: merge"
git --git-dir="$remote" show main:api/A.kt >/dev/null 2>&1 && pass "squashed into main" || fail "not on main"

# behind main: merges main into the PR, pushes, records deploy-merge, then deploys
setup; main_commit web/other.ts x; code="$(run 7)"; [ "$code" = 0 ] && pass "deploy after updating" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "

# red CI after merging main → back to Coding
setup; main_commit web/other.ts x; echo "api=FAILURE" > "$FG/ci"; code="$(run 7)"
[ "$code" = 4 ] && pass "red CI after merge → Coding" || fail "exit $code: $(cat "$T/out")"

# failed health check after merge → revert PR, reopened, blocked
setup; echo 22 > "$FG/curl"; code="$(run 7)"
[ "$code" = 6 ] && pass "failed health check → revert" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/calls")" "pr create"
assert_contains "$(cat "$FG/labels")" reopened
git --git-dir="$remote" rev-parse -q --verify refs/heads/revert/7 >/dev/null && pass "revert branch pushed" || fail "no revert branch"

# a run that stopped after merging resumes at production
setup; run 7 >/dev/null; echo "Ready for Prod" > "$FG/status"; : > "$FG/calls"
code="$(run 7)"; [ "$code" = 0 ] && [ "$(cat "$FG/status")" = Done ] && pass "resumes after the merge" || fail "exit $code: $(cat "$T/out")"
case "$(cat "$FG/calls")" in *"pr merge"*) fail "merged twice" ;; *) pass "no second merge" ;; esac


# a branch whose name has a "t" (and a tab-free pattern): the PR is still found
setup; echo feat/7-tests-at-last > "$FG/branch"; git -C "$repo" push -q origin feat/7-x:feat/7-tests-at-last
code="$(run 7)"; [ "$code" = 0 ] && pass "branch name with t deploys" || fail "exit $code: $(cat "$T/out")"
finish
