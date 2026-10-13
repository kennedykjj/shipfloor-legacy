#!/usr/bin/env bash
# The dispatcher takes cards from the top of the queue the owner ordered (#128), with the real board.sh over the fake gh.
#   AC-4  two cards in Ready for Dev and one develop slot: the dispatcher starts the first of the board, not the lowest
#         number; with the first blocked it starts the second; and the board query asks for the project's order
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export SHIPFLOOR_HOME="$(mktemp -d)"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
  unset SHIPFLOOR_MAX_PARALLEL FAKE_GH_NO_JQ
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$SHIPFLOOR_HOME/registry.tsv"
  printf 'pool: 4\nstages: {refine: 1, develop: 1, validate: 1, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  tmp="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "$(cat) $*" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  printf '#!/usr/bin/env bash\necho "deploy $*" >> "%s/launched"\n' "$tmp" > "$tmp/deploy"
  chmod +x "$tmp/claude" "$tmp/deploy"
  printf '#!/usr/bin/env bash\nexec bash "%s/board.sh" "$@"\n' "$FACTORY_DIR" > "$tmp/board"; chmod +x "$tmp/board"  # the real one, not executable on every checkout
  export FACTORY_CLAUDE="$tmp/claude" FACTORY_DEPLOY="$tmp/deploy" FACTORY_BOARD="$tmp/board"
  : > "$tmp/launched"
}
launched() { cat "$tmp/launched"; }

# #41 is above #40 on the board: the top one starts, though its number is higher
setup
printf 'PVTI_41\t41\tReady for Dev\nPVTI_9\t9\tInbox\nPVTI_40\t40\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
run_dispatch
out="$(launched)"
assert_contains "$out" "/sf:develop 41"
case "$out" in *"/sf:develop 40"*) fail "AC-4 the second card started too, with one develop slot" ;; *) pass "AC-4 one slot: only the top card started" ;; esac
grep -q 'orderBy: {field: POSITION, direction: ASC}' "$FAKE_GH_DIR/calls" && pass "AC-4 the board query asks for the project's order" || fail "AC-4 the board query does not name the order"

# the top card is blocked: the dispatcher skips it and starts the next one down
setup
printf 'PVTI_41\t41\tReady for Dev\nPVTI_40\t40\tReady for Dev\nPVTI_42\t42\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
echo blocked > "$FAKE_GH_DIR/labels-41"
run_dispatch
out="$(launched)"
assert_contains "$out" "/sf:develop 40"
case "$out" in *"/sf:develop 41"*|*"/sf:develop 42"*) fail "AC-4 a card other than the first that can start started" ;; *) pass "AC-4 only the first card that can start started" ;; esac

# the same in Ready for Refinement, for the refine stage
setup
printf 'PVTI_51\t51\tReady for Refinement\nPVTI_50\t50\tReady for Refinement\n' > "$FAKE_GH_DIR/items.tsv"
run_dispatch
out="$(launched)"
assert_contains "$out" "/sf:refine 51"
case "$out" in *"/sf:refine 50"*) fail "AC-4 refine started the second card too" ;; *) pass "AC-4 refine takes the top of Ready for Refinement" ;; esac
finish
