#!/usr/bin/env bash
# deploy.sh fixes that need a second look: one larger than deploy.fix_max_lines waits in Staged, two red rounds
# go back to Coding, a failed CI run on main is run again before any revert.
source "$(dirname "$0")/deploy-lib.sh"

# a fix larger than deploy.fix_max_lines → back to Staged, with the fix as the head to approve; nothing merged
red_round
fix api/A.kt 200; fixed="$(git -C "$FACTORY_WT_ROOT/7" rev-parse HEAD)"; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
[ "$code" = 4 ] && [ "$(cat "$FG/status")" = Staged ] && pass "large fix → Staged" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "staged-head: $fixed"
[ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$fixed" ] && pass "fix pushed for review" || fail "fix not pushed"
[ -e "$FG/merged" ] && fail "merged an unapproved fix" || pass "nothing merged"
# ...and once the owner approves it (the card back in Ready for Prod), it deploys
echo "Ready for Prod" > "$FG/status"; code="$(run 7)"; [ "$code" = 0 ] && pass "approved fix deploys" || fail "exit $code: $(cat "$T/out")"

# two rounds that leave CI red → back to Coding
red_round
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
