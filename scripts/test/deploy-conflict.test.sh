#!/usr/bin/env bash
# deploy.sh conflicts with main: migration → Coding, small → handed over, modify/delete, tampered --continue.
source "$(dirname "$0")/deploy-lib.sh"

# a migration conflicting with main → back to Coding, nothing pushed
setup; on_branch "$M/V2__card.sql" card; main_commit "$M/V2__card.sql" main
before="$(git --git-dir="$remote" rev-parse feat/7-x)"; code="$(run 7)"
[ "$code" = 4 ] && pass "migration conflict → back to Coding" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = Coding ] && pass "card in Coding" || fail "status $(cat "$FG/status")"
[ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "nothing pushed" || fail "pushed a failed merge"
[ -z "$(git -C "$FACTORY_WT_ROOT/7" status --porcelain)" ] && pass "worktree left clean" || fail "worktree dirty"

# a small conflict → handed over (exit 3); after it is resolved, --continue finishes
setup; on_branch shared.txt card; main_commit shared.txt main; code="$(run 7)"
[ "$code" = 3 ] && pass "small conflict handed over" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$T/out")" "CONFLICT shared.txt"
echo resolved > "$FACTORY_WT_ROOT/7/shared.txt"; git -C "$FACTORY_WT_ROOT/7" add shared.txt; git -C "$FACTORY_WT_ROOT/7" commit -q --no-edit
code="$(run 7 --continue)"; [ "$code" = 0 ] && pass "--continue deploys" || fail "exit $code: $(cat "$T/out")"

# a modify/delete conflict (no markers) is handled, not a crash
setup; on_branch shared.txt card; w="$(mktemp -d)"; git clone -q "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
git -C "$w" rm -q shared.txt; git -C "$w" commit -qm "main: drop shared"; git -C "$w" push -q origin main
code="$(run 7)"; [ "$code" = 3 ] && pass "modify/delete conflict handed over" || fail "exit $code: $(cat "$T/out")"

# --continue refuses a resolution that changes files that did not conflict
setup; on_branch shared.txt card; main_commit shared.txt main; run 7 >/dev/null
echo resolved > "$FACTORY_WT_ROOT/7/shared.txt"; echo sneaky > "$FACTORY_WT_ROOT/7/api/A.kt"
git -C "$FACTORY_WT_ROOT/7" add -A; git -C "$FACTORY_WT_ROOT/7" commit -q --no-edit
code="$(run 7 --continue)"; [ "$code" = 5 ] && pass "tampered resolution blocked" || fail "exit $code: $(cat "$T/out")"

# --continue accepts files both sides changed that git merged on its own, next to a real conflict
setup; on_branch shared.txt card; on_branch lines.txt $'ONE
two
three
four
five'
main_commit shared.txt main; main_commit lines.txt $'one
two
three
four
FIVE'; code="$(run 7)"
[ "$code" = 3 ] && pass "conflict next to a clean auto-merge handed over" || fail "exit $code: $(cat "$T/out")"
echo resolved > "$FACTORY_WT_ROOT/7/shared.txt"; git -C "$FACTORY_WT_ROOT/7" add shared.txt; git -C "$FACTORY_WT_ROOT/7" commit -q --no-edit
code="$(run 7 --continue)"; [ "$code" = 0 ] && pass "auto-merged file accepted" || fail "exit $code: $(cat "$T/out")"

# ... but not when the resolver edits that auto-merged file
setup; on_branch shared.txt card; on_branch lines.txt $'ONE
two
three
four
five'
main_commit shared.txt main; main_commit lines.txt $'one
two
three
four
FIVE'; run 7 >/dev/null
echo resolved > "$FACTORY_WT_ROOT/7/shared.txt"; echo sneaky >> "$FACTORY_WT_ROOT/7/lines.txt"
git -C "$FACTORY_WT_ROOT/7" add -A; git -C "$FACTORY_WT_ROOT/7" commit -q --no-edit
code="$(run 7 --continue)"; [ "$code" = 5 ] && pass "edited auto-merged file blocked" || fail "exit $code: $(cat "$T/out")"

finish
