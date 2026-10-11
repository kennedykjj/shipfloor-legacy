#!/usr/bin/env bash
# deploy.sh repairs what breaks on top of main instead of sending the card back: a migration version main took,
# a red gate or CI handed to an agent (a small fix ships). Larger fixes and repeated rounds: deploy-fix-rounds.test.sh.
source "$(dirname "$0")/deploy-lib.sh"

# main took the card's migration version under another name: the card's file moves above it and the deploy goes on
setup; on_branch "$M/V2__card.sql" 'create table c (id int);'; main_commit "$M/V2__other.sql" 'create table o (id int);'
code="$(run 7)"; [ "$code" = 0 ] && pass "migration version collision → renumbered and deployed" || fail "exit $code: $(cat "$T/out")"
git --git-dir="$remote" cat-file -e "main:$M/V3__card.sql" 2>/dev/null && pass "card's migration is V3 on main" || fail "no V3__card.sql on main"
assert_contains "$(cat "$FG/comments")" "deploy-fix: "

# red CI after merging main → handed to an agent with the findings (exit 3), nothing sent back
red_round
[ "$code" = 3 ] && pass "red CI after merge → fix round" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "card stays in Ready for Prod" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FACTORY_HOME/tmp/7/fix.findings")" "api=FAILURE"
# ...a small fix ships with the approved head, recorded as deploy-fix
fix api/A.kt 3; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
[ "$code" = 0 ] && [ "$(cat "$FG/status")" = Done ] && pass "small fix deployed" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "deploy-fix: "

# a fix round that commits nothing → back to Coding
red_round
code="$(run 7 --continue)"; [ "$code" = 4 ] && [ "$(cat "$FG/status")" = Coding ] && pass "no fix → Coding" || fail "exit $code: $(cat "$T/out")"

# a fix that edits an acceptance test, however small, never ships: acceptance-intact sends it back to Coding
red_round
fix api/src/test/ATest.kt 1; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
[ "$code" = 4 ] && [ "$(cat "$FG/status")" = Coding ] && pass "fix in an acceptance test → Coding" || fail "exit $code: $(cat "$T/out")"
[ -e "$FG/merged" ] && fail "merged a weakened acceptance test" || pass "nothing merged"
finish
