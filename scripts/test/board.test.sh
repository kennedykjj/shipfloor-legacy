#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
BOARD="$FACTORY_DIR/board.sh"
export FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
printf 'I1\t25\t👤 Ready for Refinement\nI2\t26\t👤 Ready for Refinement\nI3\t33\t👤 Spec Review\nI4\t40\t🤖 Coding\nI5\t41\t🤖 Validation\nI6\t47\t👤 Staged\n' > "$FAKE_GH_DIR/items.tsv"

[ "$(bash "$BOARD" status 33)" = "Spec Review" ] && pass "status strips the owner emoji" || fail "status kept the emoji: $(bash "$BOARD" status 33)"
assert_contains "$(bash "$BOARD" count Coding Validation)" "2"
assert_contains "$(bash "$BOARD" count "Spec Review")" "1"
assert_contains "$(bash "$BOARD" first "Ready for Refinement")" "25"
echo blocked > "$FAKE_GH_DIR/labels-25"
assert_contains "$(bash "$BOARD" first "Ready for Refinement")" "26"
echo blocked > "$FAKE_GH_DIR/labels-26"
[ -z "$(bash "$BOARD" first "Ready for Refinement")" ] && pass "all blocked → empty" || fail "expected empty"

assert_exit 0 bash "$BOARD" move 25 "Technical Refinement"
assert_contains "$(cat "$FAKE_GH_DIR/edits")" "--id I1"
assert_contains "$(cat "$FAKE_GH_DIR/edits")" "--single-select-option-id opt3"
for target in "Ready for Refinement" "Ready for Dev" "Ready for Prod"; do
  assert_exit 3 bash "$BOARD" move 40 "$target"
done
assert_exit 3 bash "$BOARD" move 33 "Ready for Refinement"
assert_exit 3 bash "$BOARD" move 33 "Coding"          # leaving Spec Review
assert_exit 3 bash "$BOARD" move 47 "Done"            # leaving Staged
assert_exit 0 bash "$BOARD" move 40 "Validation"

touch "$FAKE_GH_DIR/fail"
assert_exit 1 bash "$BOARD" count Coding
finish
