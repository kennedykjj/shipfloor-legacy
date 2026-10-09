#!/usr/bin/env bash
# board.sh spends little GraphQL: snapshot reuse and REST label lookups.
source "$(dirname "$0")/lib.sh"
BOARD="$FACTORY_DIR/board.sh"
export FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
printf 'I1\t25\t👤 Ready for Refinement\nI4\t40\t🤖 Coding\n' > "$FAKE_GH_DIR/items.tsv"
snap="$(mktemp)"; bash "$BOARD" snapshot > "$snap"
assert_contains "$(cat "$snap")" "40"
touch "$FAKE_GH_DIR/fail"   # any gh call now fails
assert_contains "$(FACTORY_BOARD_SNAPSHOT="$snap" bash "$BOARD" count Coding)" "1"
rm "$FAKE_GH_DIR/fail"
: > "$FAKE_GH_DIR/calls"
bash "$BOARD" first "Ready for Refinement" >/dev/null
case "$(cat "$FAKE_GH_DIR/calls")" in *"issue view"*) fail "labels via GraphQL issue view" ;; *"api repos/kennedykjj/pickio/issues/25"*) pass "labels via REST" ;; *) fail "no label lookup: $(cat "$FAKE_GH_DIR/calls")" ;; esac
# the board read asks only for issue number and Status (not every field of every card)
: > "$FAKE_GH_DIR/calls"; bash "$BOARD" snapshot >/dev/null
case "$(cat "$FAKE_GH_DIR/calls")" in *"project item-list"*) fail "uses the expensive item-list" ;; *'fieldValueByName(name: "Status")'*) pass "cheap status-only query" ;; *) fail "unexpected query: $(cat "$FAKE_GH_DIR/calls")" ;; esac
finish
