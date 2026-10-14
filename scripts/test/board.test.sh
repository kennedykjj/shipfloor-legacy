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

# the board comes from the project config; ids are looked up once and cached
assert_contains "$(cat "$FAKE_GH_DIR/edits")" "--project-id PVT_x --id I1 --field-id FLD_x"
q="$(grep 'api graphql' "$FAKE_GH_DIR/calls" | head -1)"
assert_contains "$q" 'repositoryOwner(login: "acme")'
assert_contains "$q" 'projectV2(number: 7)'
assert_contains "$(grep -c 'project view' "$FAKE_GH_DIR/calls")" "1"
assert_contains "$(grep -E 'project (view|field-list)' "$FAKE_GH_DIR/calls" | head -1)" "--owner acme"
bad="$(mktemp)"; sed 's/owner: acme/owner: "a\\" } evil"/' "$FACTORY_CONFIG" > "$bad"
assert_exit 2 env FACTORY_CONFIG="$bad" bash "$BOARD" items

# blocked:infra is not eligible either; infra lists those cards; label adds and removes labels
echo "blocked:infra" > "$FAKE_GH_DIR/labels-41"
[ -z "$(bash "$BOARD" eligible Validation)" ] && pass "blocked:infra is not eligible" || fail "eligible kept a blocked:infra card"
printf '41
' > "$FAKE_GH_DIR/infra"; assert_contains "$(bash "$BOARD" infra)" "41"
assert_exit 0 bash "$BOARD" label 41 remove blocked:infra
assert_contains "$(cat "$FAKE_GH_DIR/calls")" "api -X DELETE repos/acme/shop/issues/41/labels/blocked:infra"
touch "$FAKE_GH_DIR/fail"
assert_exit 1 bash "$BOARD" count Coding

# ---- #161 (PY-08): pins what board.sh does today, odd results included. A fresh fake board for what follows.
export FAKE_GH_DIR="$(mktemp -d)"
printf 'I1\t25\t👤 Ready for Refinement\nI3\t33\t👤 Spec Review\nI4\t40\t🤖 Coding\nI5\t41\t🤖 Validation\n' > "$FAKE_GH_DIR/items.tsv"

# AC-1 items and snapshot: snapshot is "n<TAB>status<TAB>itemId", items is "n<TAB>status"; the 👤/🤖 mark is stripped
exp3=$'25\tReady for Refinement\tI1\n33\tSpec Review\tI3\n40\tCoding\tI4\n41\tValidation\tI5'
exp2=$'25\tReady for Refinement\n33\tSpec Review\n40\tCoding\n41\tValidation'
[ "$(bash "$BOARD" snapshot)" = "$exp3" ] && pass "AC-1 snapshot prints n<TAB>status<TAB>itemId with the mark stripped" || fail "AC-1 snapshot differs: $(bash "$BOARD" snapshot | od -c | head -5)"
[ "$(bash "$BOARD" items)" = "$exp2" ] && pass "AC-1 items prints n<TAB>status with the mark stripped" || fail "AC-1 items differs: $(bash "$BOARD" items | od -c | head -5)"
case "$(bash "$BOARD" snapshot)$(bash "$BOARD" items)" in *👤*|*🤖*) fail "AC-1 an owner mark is left in the output" ;; *) pass "AC-1 no owner mark in the output" ;; esac

# AC-1 label add: a POST of labels[]=<name> to the issue's labels
assert_exit 0 bash "$BOARD" label 41 add ui
assert_contains "$(cat "$FAKE_GH_DIR/calls")" "api -X POST repos/acme/shop/issues/41/labels -f labels[]=ui"
assert_exit 2 bash "$BOARD" label 41 toggle ui

# AC-1 move: exit 1 for a card that is not on the board
assert_exit 1 bash "$BOARD" move 999 Coding
assert_contains "$(bash "$BOARD" move 999 Coding 2>&1)" "issue #999 is not on the board"
# AC-1 move: exit 1 for a column the board has no option for (the name is a known column, the board lacks its option)
cat > "$FAKE_GH_DIR/gh-no-validation" <<EOS
#!/usr/bin/env bash
case "\$*" in *"options[]"*) "$FACTORY_DIR/test/fake-gh" "\$@" | grep -v Validation ;; *) exec "$FACTORY_DIR/test/fake-gh" "\$@" ;; esac
EOS
chmod +x "$FAKE_GH_DIR/gh-no-validation"
assert_exit 1 env FACTORY_GH="$FAKE_GH_DIR/gh-no-validation" bash "$BOARD" move 40 Validation
assert_contains "$(FACTORY_GH="$FAKE_GH_DIR/gh-no-validation" bash "$BOARD" move 40 Validation 2>&1)" "unknown status 'Validation'"
# a name that is not a column at all stops earlier, with exit 2
assert_exit 2 bash "$BOARD" move 40 Nowhere

# AC-1 move reads the current status from a stale FACTORY_BOARD_SNAPSHOT, not from the board: today's behavior, pinned
# (the owner-only check runs on that stale status). The board has 25 in Ready for Refinement and 33 in Spec Review.
snap="$(mktemp)"; printf '25\tSpec Review\tIsnap25\n33\tCoding\tIsnap33\n' > "$snap"
assert_exit 3 env FACTORY_BOARD_SNAPSHOT="$snap" bash "$BOARD" move 25 Coding   # the board would let it go; the snapshot says Spec Review
assert_contains "$(FACTORY_BOARD_SNAPSHOT="$snap" bash "$BOARD" move 25 Coding 2>&1)" "only the owner moves cards out of 'Spec Review'"
: > "$FAKE_GH_DIR/edits"
assert_exit 0 env FACTORY_BOARD_SNAPSHOT="$snap" bash "$BOARD" move 33 Validation   # the board says Spec Review (owner only); the snapshot says Coding
assert_contains "$(cat "$FAKE_GH_DIR/edits")" "--id Isnap33"                         # and the item id comes from the snapshot too
[ "$(FACTORY_BOARD_SNAPSHOT="$snap" bash "$BOARD" status 33)" = Coding ] && pass "AC-1 status reads the snapshot when given" || fail "AC-1 status ignored the snapshot"
[ "$(FACTORY_BOARD_SNAPSHOT="$snap" bash "$BOARD" snapshot | cut -f1 | tr '\n' ' ')" = "25 33 40 41 " ] && pass "AC-1 snapshot always reads the board, never the snapshot file" || fail "AC-1 snapshot read the snapshot file"

# AC-1 the 100-item read limit: the query asks for first: 100 and a board of 101 cards loses the 101st, silently.
# A fake gh that, like GitHub, returns at most the "first: N" it was asked for.
export REAL_FAKE_GH="$FACTORY_DIR/test/fake-gh"
cat > "$FAKE_GH_DIR/gh-limit" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  "api graphql"*) n="$(printf '%s' "$*" | grep -o 'first: [0-9]*' | head -1 | grep -o '[0-9]*$')"; "$REAL_FAKE_GH" "$@" | head -n "$n" ;;
  *) exec "$REAL_FAKE_GH" "$@" ;;
esac
EOS
chmod +x "$FAKE_GH_DIR/gh-limit"
awk 'BEGIN{for(i=1;i<=101;i++) printf "I%d\t%d\t🤖 Coding\n", i, i}' > "$FAKE_GH_DIR/items.tsv"
export FACTORY_GH="$FAKE_GH_DIR/gh-limit"
: > "$FAKE_GH_DIR/calls"
assert_contains "$(bash "$BOARD" count Coding)" "100"
[ "$(bash "$BOARD" count Coding)" = 100 ] && pass "AC-1 count sees 100 cards of 101" || fail "AC-1 count of 101 cards: $(bash "$BOARD" count Coding)"
[ "$(bash "$BOARD" items | wc -l | tr -d ' ')" = 100 ] && pass "AC-1 items lists 100 of the 101 cards" || fail "AC-1 items lists $(bash "$BOARD" items | wc -l) cards"
[ "$(bash "$BOARD" items | cut -f1 | tail -1)" = 100 ] && pass "AC-1 the last card read is 100" || fail "AC-1 last card is $(bash "$BOARD" items | cut -f1 | tail -1)"
[ -z "$(bash "$BOARD" status 101)" ] && pass "AC-1 item 101 has no status: it is dropped by first: 100" || fail "AC-1 item 101 was read: $(bash "$BOARD" status 101)"
[ -z "$(bash "$BOARD" snapshot | awk -F'\t' '$1==101')" ] && pass "AC-1 item 101 is not in the snapshot" || fail "AC-1 item 101 is in the snapshot"
assert_exit 1 bash "$BOARD" move 101 Validation
assert_contains "$(bash "$BOARD" move 101 Validation 2>&1)" "issue #101 is not on the board"
assert_contains "$(grep 'api graphql' "$FAKE_GH_DIR/calls" | head -1)" "items(first: 100, orderBy: {field: POSITION, direction: ASC})"
finish
