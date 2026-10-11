#!/usr/bin/env bash
# deploy.sh repairs what breaks on top of main instead of sending the card back: a migration version main took,
# a red gate or CI (two agent rounds; a small fix ships, a larger one waits in Staged), a failed CI run on main.
source "$(dirname "$0")/deploy-lib.sh"
fix() {  # fix <file> <lines>: what the agent of a fix round commits in the card's worktree
  local w="$FACTORY_WT_ROOT/7"; mkdir -p "$w/$(dirname "$1")"; seq 1 "$2" > "$w/$1"
  git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm "fix: $1"
}

# main took the card's migration version under another name: the card's file moves above it and the deploy goes on
setup; on_branch "$M/V2__card.sql" 'create table c (id int);'; main_commit "$M/V2__other.sql" 'create table o (id int);'
code="$(run 7)"; [ "$code" = 0 ] && pass "migration version collision → renumbered and deployed" || fail "exit $code: $(cat "$T/out")"
git --git-dir="$remote" cat-file -e "main:$M/V3__card.sql" 2>/dev/null && pass "card's migration is V3 on main" || fail "no V3__card.sql on main"
assert_contains "$(cat "$FG/comments")" "deploy-fix: "

# red CI after merging main → handed to an agent with the findings (exit 3), nothing sent back
setup; main_commit web/other.ts x; echo "api=FAILURE" > "$FG/ci"; code="$(run 7)"
[ "$code" = 3 ] && pass "red CI after merge → fix round" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "card stays in Ready for Prod" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FACTORY_HOME/tmp/7/fix.findings")" "api=FAILURE"
# ...a small fix ships with the approved head, recorded as deploy-fix
fix api/A.kt 3; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
[ "$code" = 0 ] && [ "$(cat "$FG/status")" = Done ] && pass "small fix deployed" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "deploy-fix: "

# a fix round that commits nothing → back to Coding
setup; main_commit web/other.ts x; echo "api=FAILURE" > "$FG/ci"; run 7 >/dev/null
code="$(run 7 --continue)"; [ "$code" = 4 ] && [ "$(cat "$FG/status")" = Coding ] && pass "no fix → Coding" || fail "exit $code: $(cat "$T/out")"

# a fix larger than deploy.fix_max_lines → back to Staged, with the fix as the head to approve; nothing merged
setup; main_commit web/other.ts x; echo "api=FAILURE" > "$FG/ci"; run 7 >/dev/null
fix api/A.kt 200; fixed="$(git -C "$FACTORY_WT_ROOT/7" rev-parse HEAD)"; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
[ "$code" = 4 ] && [ "$(cat "$FG/status")" = Staged ] && pass "large fix → Staged" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "staged-head: $fixed"
[ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$fixed" ] && pass "fix pushed for review" || fail "fix not pushed"
[ -e "$FG/merged" ] && fail "merged an unapproved fix" || pass "nothing merged"
# ...and once the owner approves it (the card back in Ready for Prod), it deploys
echo "Ready for Prod" > "$FG/status"; code="$(run 7)"; [ "$code" = 0 ] && pass "approved fix deploys" || fail "exit $code: $(cat "$T/out")"

# a fix that edits an acceptance test, however small, never ships: acceptance-intact sends it back to Coding
setup; main_commit web/other.ts x; echo "api=FAILURE" > "$FG/ci"; run 7 >/dev/null
fix api/src/test/ATest.kt 1; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
[ "$code" = 4 ] && [ "$(cat "$FG/status")" = Coding ] && pass "fix in an acceptance test → Coding" || fail "exit $code: $(cat "$T/out")"
[ -e "$FG/merged" ] && fail "merged a weakened acceptance test" || pass "nothing merged"

# two rounds that leave CI red → back to Coding
setup; main_commit web/other.ts x; echo "api=FAILURE" > "$FG/ci"; run 7 >/dev/null
fix api/A.kt 2; code="$(run 7 --continue)"; [ "$code" = 3 ] && pass "second fix round" || fail "exit $code: $(cat "$T/out")"
fix api/A.kt 3; code="$(run 7 --continue)"
[ "$code" = 4 ] && [ "$(cat "$FG/status")" = Coding ] && pass "two red rounds → Coding" || fail "exit $code: $(cat "$T/out")"

# the CI run on main fails once and passes when its failed jobs run again: no revert
setup; sed -i 's/^deploy: {/deploy: {ci_workflow: CI, /' "$FACTORY_CONFIG"
printf '#!/usr/bin/env bash\ncase "$*" in "run list"*) echo 1; exit 0 ;; esac\nexec bash "%s" "$@"\n' "$FACTORY_DIR/test/fake-gh-deploy" > "$T/gh"
chmod +x "$T/gh"; export FACTORY_GH="$T/gh"; echo "completed failure" > "$FG/concl-1"; echo "completed success" > "$FG/rerun-1"
code="$(run 7)"; [ "$code" = 0 ] && [ "$(cat "$FG/status")" = Done ] && pass "failed CI on main reruns and passes" || fail "exit $code: $(cat "$T/out")"
case "$(cat "$FG/calls")" in *"pr create"*) fail "reverted a run that passed on the rerun" ;; *) pass "no revert" ;; esac
finish
