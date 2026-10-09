#!/usr/bin/env bash
# Regression tests for review findings on board.sh.
source "$(dirname "$0")/lib.sh"
BOARD="$FACTORY_DIR/board.sh"
export FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
printf 'I1\t25\t👤 Ready for Refinement\nI2\t26\t👤 Ready for Refinement\nI4\t40\t🤖 Coding\n' > "$FAKE_GH_DIR/items.tsv"

# C3: only the ten exact column names are accepted as targets
assert_exit 2 bash "$BOARD" move 40 'Ready for Prod" or "a"=="b'
assert_exit 2 bash "$BOARD" move 40 'Nonexistent'
[ ! -s "$FAKE_GH_DIR/edits" ] && pass "no edit for rejected targets" || fail "edited the board"

# I2: a failing label lookup does not release the card
touch "$FAKE_GH_DIR/fail-issue-view"
assert_exit 1 bash "$BOARD" first "Ready for Refinement"
[ -z "$(bash "$BOARD" first "Ready for Refinement" 2>/dev/null)" ] && pass "nothing printed on label failure" || fail "printed a card"
rm "$FAKE_GH_DIR/fail-issue-view"

# I2: blocked detection does not race with gh output (many labels)
for i in $(seq 1 3000); do echo "label-$i"; done > "$FAKE_GH_DIR/labels-25"; sed -i '1i blocked' "$FAKE_GH_DIR/labels-25"
assert_contains "$(bash "$BOARD" first "Ready for Refinement")" "26"
finish
