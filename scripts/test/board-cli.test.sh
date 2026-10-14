#!/usr/bin/env bash
# board.sh and setup-board.sh through real processes with test/fake-gh (the behavior is in py/board_*.py, in process):
# stdout, stderr and exit codes, FACTORY_GH and never a plain gh, and the GraphQL budget (a snapshot spares the board
# read, labels by REST, a status-only query).
source "$(dirname "$0")/lib.sh"
BOARD="$FACTORY_DIR/board.sh"
export FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
printf 'I1\t25\t👤 Ready for Refinement\nI3\t33\t👤 Spec Review\nI4\t40\t🤖 Coding\n' > "$FAKE_GH_DIR/items.tsv"
# a plain `gh` on PATH that only records: the scripts must go through FACTORY_GH
mkdir -p "$FAKE_GH_DIR/plain"; printf '#!/usr/bin/env bash\necho "$*" >> "%s/plain-calls"\nexit 1\n' "$FAKE_GH_DIR" > "$FAKE_GH_DIR/plain/gh"
chmod +x "$FAKE_GH_DIR/plain/gh"; export PATH="$FAKE_GH_DIR/plain:$PATH"

[ "$(bash "$BOARD" status 33)" = "Spec Review" ] && pass "status prints the column, owner mark stripped" || fail "status: $(bash "$BOARD" status 33)"
[ "$(bash "$BOARD" items)" = $'25\tReady for Refinement\n33\tSpec Review\n40\tCoding' ] && pass "items: n<TAB>status a line" || fail "items: $(bash "$BOARD" items)"
assert_exit 0 bash "$BOARD" move 40 Validation
grep -q -- '--project-id PVT_x --id I4 --field-id FLD_x --single-select-option-id opt7' "$FAKE_GH_DIR/edits" && pass "move edits the card through FACTORY_GH" || fail "edits: $(cat "$FAKE_GH_DIR/edits")"
out="$(bash "$BOARD" move 33 Coding 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 3 ] && [ "$out" = "move: only the owner moves cards out of 'Spec Review'" ] && pass "owner-only move: exit 3, the reason on stderr" || fail "owner-only: $rc $out"
out="$(bash "$BOARD" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && case "$out" in "usage: board.sh items|status <n>|count <status>...|first <status>|move <n> <status>|"*) true ;; *) false ;; esac \
  && [ -z "$(bash "$BOARD" 2>/dev/null)" ] && pass "no subcommand: exit 2, the usage line on stderr only" || fail "usage: $rc $out"

# the GraphQL budget: the read asks only for number and Status; labels by REST; a snapshot spares the board read
: > "$FAKE_GH_DIR/calls"; snap="$(mktemp)"; bash "$BOARD" snapshot > "$snap"
case "$(cat "$FAKE_GH_DIR/calls")" in *"project item-list"*) fail "the board read uses the expensive item-list" ;;
  *'fieldValueByName(name: "Status")'*) pass "the board read is the status-only query" ;; *) fail "query: $(cat "$FAKE_GH_DIR/calls")" ;; esac
: > "$FAKE_GH_DIR/calls"; bash "$BOARD" first "Ready for Refinement" >/dev/null
grep -q '^api repos/acme/shop/issues/25 ' "$FAKE_GH_DIR/calls" && ! grep -q 'issue view' "$FAKE_GH_DIR/calls" && pass "labels read by REST" || fail "calls: $(cat "$FAKE_GH_DIR/calls")"
touch "$FAKE_GH_DIR/fail"
[ "$(FACTORY_BOARD_SNAPSHOT="$snap" bash "$BOARD" count Coding)" = 1 ] && pass "with a snapshot, count makes no gh call" || fail "count with a snapshot and gh down"
assert_exit 1 bash "$BOARD" count Coding
rm "$FAKE_GH_DIR/fail"

# setup-board.sh: exit 0, the snapshot line and the counts on stdout; no Status field → exit 1 and the reason
cat > "$FAKE_GH_DIR/gh-setup" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  "project item-list"*group_by*) printf 'Coding: 1\n' ;;
  "project item-list"*) printf 'I4\t🤖 Coding\n' ;;
  "label create"*|"api graphql"*) ;;
  *) exec "$FACTORY_DIR/test/fake-gh" "$@" ;;
esac
EOS
chmod +x "$FAKE_GH_DIR/gh-setup"
SNAPSHOT="$FAKE_GH_DIR/snap.tsv" FACTORY_GH="$FAKE_GH_DIR/gh-setup" FACTORY_DIR="$FACTORY_DIR" bash "$FACTORY_DIR/setup-board.sh" > "$FAKE_GH_DIR/out" 2> "$FAKE_GH_DIR/err"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$FAKE_GH_DIR/out")" = "snapshot ($FAKE_GH_DIR/snap.tsv): 1 items"$'\n'"Coding: 1" ] && [ ! -s "$FAKE_GH_DIR/err" ] && pass "setup-board.sh: exit 0, the snapshot line and the counts on stdout" || fail "setup-board: $rc $(cat "$FAKE_GH_DIR/out" "$FAKE_GH_DIR/err")"
[ ! -e "$FAKE_GH_DIR/plain-calls" ] && pass "board.sh and setup-board.sh call FACTORY_GH, never a plain gh" || fail "plain gh called: $(cat "$FAKE_GH_DIR/plain-calls")"
printf '#!/usr/bin/env bash\ncase "$*" in "project view"*) echo PVT_x ;; esac\n' > "$FAKE_GH_DIR/gh-nofield"; chmod +x "$FAKE_GH_DIR/gh-nofield"
out="$(FACTORY_GH="$FAKE_GH_DIR/gh-nofield" bash "$FACTORY_DIR/setup-board.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "setup-board: project acme/7 has no Status field" ] && pass "setup-board.sh: no Status field → exit 1" || fail "no field: $rc $out"
finish
