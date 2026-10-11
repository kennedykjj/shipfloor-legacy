#!/usr/bin/env bash
# deploy.sh run again after it merged: a later green CI run on main finishes the card, a stopped run resumes.
source "$(dirname "$0")/deploy-lib.sh"

# the merge commit's own CI run failed for a reason main has since fixed: a retry reads the newest
# run on main, finishes the card and opens no second revert
setup; sed -i 's/^deploy: {/deploy: {ci_workflow: CI, /' "$FACTORY_CONFIG"
# the merge commit is not known before the merge: every sha answers run 1 until the retry
printf '#!/usr/bin/env bash\ncase "$*" in "run list"*) [ -e "$FG/fixed" ] || { echo 1; exit 0; } ;; esac\nexec bash "%s" "$@"\n' "$FACTORY_DIR/test/fake-gh-deploy" > "$T/gh"
chmod +x "$T/gh"; export FACTORY_GH="$T/gh"; echo "completed failure" > "$FG/concl-1"
code="$(run 7)"; [ "$code" = 6 ] && pass "red CI on the merge commit → revert" || fail "exit $code: $(cat "$T/out")"
main_commit web/fix.ts fixed; head="$(git --git-dir="$remote" rev-parse refs/heads/main)"
touch "$FG/fixed"; echo 1 > "$FG/run-$(cat "$FG/merged")"; echo 2 > "$FG/run-$head"; echo "completed success" > "$FG/concl-2"
echo "Ready for Prod" > "$FG/status"; : > "$FG/calls"
code="$(run 7)"; [ "$code" = 0 ] && [ "$(cat "$FG/status")" = Done ] && pass "a later green run on main finishes the card" || fail "exit $code: $(cat "$T/out")"
case "$(cat "$FG/calls")" in *"pr create"*) fail "opened a second revert" ;; *) pass "no second revert" ;; esac

# a run that stopped after merging resumes at production
setup; run 7 >/dev/null; echo "Ready for Prod" > "$FG/status"; : > "$FG/calls"
code="$(run 7)"; [ "$code" = 0 ] && [ "$(cat "$FG/status")" = Done ] && pass "resumes after the merge" || fail "exit $code: $(cat "$T/out")"
case "$(cat "$FG/calls")" in *"pr merge"*) fail "merged twice" ;; *) pass "no second merge" ;; esac
finish
