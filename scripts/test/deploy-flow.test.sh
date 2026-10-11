#!/usr/bin/env bash
# deploy.sh happy paths and failures after merge: Done, merge of main, health check revert, language.
source "$(dirname "$0")/deploy-lib.sh"

# up to date head: merged, health checked, Done
setup; code="$(run 7)"; [ "$code" = 0 ] && pass "deploy done" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = Done ] && pass "card in Done" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "Deployed: merge"
git --git-dir="$remote" show main:api/A.kt >/dev/null 2>&1 && pass "squashed into main" || fail "not on main"

# behind main: merges main into the PR, pushes, records deploy-merge, then deploys
setup; main_commit web/other.ts x; code="$(run 7)"; [ "$code" = 0 ] && pass "deploy after updating" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "

# failed health check after merge → revert PR, reopened, blocked
setup; echo 22 > "$FG/curl"; code="$(run 7)"
[ "$code" = 6 ] && pass "failed health check → revert" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/calls")" "pr create"
assert_contains "$(cat "$FG/labels")" reopened
git --git-dir="$remote" rev-parse -q --verify refs/heads/revert/7 >/dev/null && pass "revert branch pushed" || fail "no revert branch"

# a branch whose name has a "t" (and a tab-free pattern): the PR is still found
setup; echo feat/7-tests-at-last > "$FG/branch"; git -C "$repo" push -q origin feat/7-x:feat/7-tests-at-last
code="$(run 7)"; [ "$code" = 0 ] && pass "branch name with t deploys" || fail "exit $code: $(cat "$T/out")"
# language: the log line and the card comment come out in the project's language; markers stay as they are
setup; echo "language: pt-BR" >> "$FACTORY_CONFIG"; main_commit web/other.ts x; code="$(run 7)"
[ "$code" = 0 ] && pass "pt-BR deploy done" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$T/out")" "main mesclada no PR"
assert_contains "$(cat "$FG/comments")" "Deploy feito: merge"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "
finish
