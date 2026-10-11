#!/usr/bin/env bash
# deploy.sh --continue next to a file git merged on its own: accepted as merged, blocked when the resolver edits it.
source "$(dirname "$0")/deploy-lib.sh"

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
