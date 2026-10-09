#!/usr/bin/env bash
# deploy.sh --refresh: keeps a Staged card on top of main, never merges, leaves conflicts.
source "$(dirname "$0")/deploy-lib.sh"

# refresh: behind main → pushed and recorded, card stays Staged; conflict → untouched
setup; echo Staged > "$FG/status"; main_commit web/other.ts x; code="$(run 7 --refresh)"
[ "$code" = 0 ] && [ "$(cat "$FG/status")" = Staged ] && pass "refresh keeps the card staged" || fail "exit $code / $(cat "$FG/status"): $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "
case "$(cat "$FG/calls")" in *"pr merge"*) fail "refresh merged the PR" ;; *) pass "refresh never merges" ;; esac
setup; echo Staged > "$FG/status"; on_branch shared.txt card; main_commit shared.txt main; before="$(git --git-dir="$remote" rev-parse feat/7-x)"
code="$(run 7 --refresh)"; [ "$code" = 0 ] && [ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "refresh leaves conflicts to the deploy" || fail "exit $code: $(cat "$T/out")"

finish
