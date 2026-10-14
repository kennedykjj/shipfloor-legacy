#!/usr/bin/env bash
# setup-board.sh (#161, PY-08): what it does to the board and the labels, with a fake gh that FACTORY_GH names.
source "$(dirname "$0")/lib.sh"
SETUP="$FACTORY_DIR/setup-board.sh"
d="$(mktemp -d)"; export FAKE_GH_DIR="$d"
mkdir -p "$d/plain"

# a plain `gh` on PATH that only records: setup-board.sh must go through FACTORY_GH and never reach this one
printf '#!/usr/bin/env bash\necho "$*" >> "$FAKE_GH_DIR/plain-gh-calls"\nexit 1\n' > "$d/plain/gh"; chmod +x "$d/plain/gh"

# the fake gh, as the board's own commands call it; everything it is asked is recorded in $d/calls
cat > "$d/gh" <<'EOS'
#!/usr/bin/env bash
d="$FAKE_GH_DIR"; args="$*"
printf '%s\n' "$args" >> "$d/calls"
case "$args" in
  "project view"*) echo PVT_x ;;
  "project field-list"*"| .id") echo FLD_x ;;
  "project field-list"*)
    i=0; for s in "👤 Inbox" "👤 Ready for Refinement" "🤖 Technical Refinement" "👤 Spec Review" "👤 Ready for Dev" "🤖 Coding" "🤖 Validation" "👤 Staged" "👤 Ready for Prod" "🤖 Done"; do
      i=$((i+1)); printf '%s\topt%s\n' "$s" "$i"; done ;;
  "project item-list"*group_by*) cat "$d/counts" ;;
  "project item-list"*) cat "$d/board.tsv" ;;
  "api graphql"*) ;;
  "project item-edit"*) ;;
  "label create"*) ;;
  *) echo "fake gh: unexpected: $args" >&2; exit 9 ;;
esac
EOS
chmod +x "$d/gh"
# the board before: a card per mark, one already plain, one with no Status, one whose status has no column
printf 'I1\t👤 Ready for Refinement\nI2\t🤖 Coding\nI3\t\nI4\t🗑 Old Column\nI5\tDone\n' > "$d/board.tsv"
printf 'Coding: 1\nDone: 1\nReady for Refinement: 1\n' > "$d/counts"

export FACTORY_GH="$d/gh"
H="$(mktemp -d)"; export FACTORY_HOME="$H"; echo "PVT_x FLD_x" > "$H/board-ids"
snap="$d/snap.tsv"
out="$(PATH="$d/plain:$PATH" SNAPSHOT="$snap" bash "$SETUP" 2> "$d/err")"; rc=$?
[ "$rc" -eq 0 ] && pass "AC-2 setup-board exits 0 with the fake gh" || fail "AC-2 setup-board exit $rc: $(cat "$d/err")"
[ ! -s "$d/plain-gh-calls" ] && pass "AC-2 setup-board calls FACTORY_GH, never plain gh" || fail "AC-2 setup-board called plain gh: $(cat "$d/plain-gh-calls")"

# the 10 options with their marks, colors and descriptions, written in one mutation on the Status field
mut="$(grep 'updateProjectV2Field' "$d/calls")"
assert_contains "$mut" 'fieldId:"FLD_x"'
assert_contains "$mut" '{name:"👤 Inbox",color:GRAY,description:"Idea captured"},'
assert_contains "$mut" '{name:"👤 Ready for Refinement",color:BLUE,description:"Owner picked it; refine queue"},'
assert_contains "$mut" '{name:"🤖 Technical Refinement",color:PINK,description:"Spec being written"},'
assert_contains "$mut" '{name:"👤 Spec Review",color:PINK,description:"Spec ready; waits for the owner"},'
assert_contains "$mut" '{name:"👤 Ready for Dev",color:BLUE,description:"Spec approved; develop queue"},'
assert_contains "$mut" '{name:"🤖 Coding",color:YELLOW,description:"Acceptance tests and implementation"},'
assert_contains "$mut" '{name:"🤖 Validation",color:ORANGE,description:"Validate queue: review, PR and CI"},'
assert_contains "$mut" '{name:"👤 Staged",color:PURPLE,description:"PR open and CI green; waits for the owner"},'
assert_contains "$mut" '{name:"👤 Ready for Prod",color:BLUE,description:"Released; deploy queue"},'
assert_contains "$mut" '{name:"🤖 Done",color:GREEN,description:"In production"}]'
[ "$(grep -o '{name:' <<< "$mut" | wc -l | tr -d ' ')" = 10 ] && pass "AC-2 the mutation carries exactly 10 options" || fail "AC-2 the mutation does not carry 10 options: $mut"

# every card is restored by name (the mark ignored); a card with no Status is skipped
edits="$(grep '^project item-edit' "$d/calls")"
assert_contains "$edits" "project item-edit --project-id PVT_x --id I1 --field-id FLD_x --single-select-option-id opt2"
assert_contains "$edits" "project item-edit --project-id PVT_x --id I2 --field-id FLD_x --single-select-option-id opt6"
assert_contains "$edits" "project item-edit --project-id PVT_x --id I5 --field-id FLD_x --single-select-option-id opt10"
[ "$(grep -c . <<< "$edits")" = 3 ] && pass "AC-2 three cards restored: none for the empty or the unknown status" || fail "AC-2 edits: $edits"
case "$edits" in *"--id I3 "*) fail "AC-2 a card with no Status was edited" ;; *) pass "AC-2 a card with no Status is not edited" ;; esac
# a card whose status has no column: told on stderr, left without Status
assert_contains "$(cat "$d/err")" "no column for 'Old Column' (item I4): left without Status"
case "$edits" in *"--id I4 "*) fail "AC-2 a card with no column was edited" ;; *) pass "AC-2 a card with no column is not edited" ;; esac
case "$out" in *"no column for"*) fail "AC-2 the no-column report went to stdout" ;; *) pass "AC-2 the no-column report is on stderr only" ;; esac

# the three labels
labels="$(grep '^label create' "$d/calls")"
assert_contains "$labels" "label create ui --repo acme/shop --color 1d76db --description Issue touches UI; UX/UI joins the refinement --force"
assert_contains "$labels" "label create cybersec --repo acme/shop --color b60205 --description Owner asked for a security review in the pipelines --force"
assert_contains "$labels" "label create blocked --repo acme/shop --color 000000 --description The factory stopped on this card; the owner decides --force"
[ "$(grep -c . <<< "$labels")" = 3 ] && pass "AC-2 exactly three labels created" || fail "AC-2 labels: $labels"

# the order: snapshot read, then the options rewrite, then the restore, then the labels
n_snap="$(grep -n 'project item-list.*--limit 500' "$d/calls" | head -1 | cut -d: -f1)"
n_mut="$(grep -n updateProjectV2Field "$d/calls" | head -1 | cut -d: -f1)"
n_edit="$(grep -n '^project item-edit' "$d/calls" | head -1 | cut -d: -f1)"
n_lab="$(grep -n '^label create' "$d/calls" | head -1 | cut -d: -f1)"
[ "$n_snap" -lt "$n_mut" ] && [ "$n_mut" -lt "$n_edit" ] && [ "$n_edit" -lt "$n_lab" ] && pass "AC-2 snapshot, then options, then restore, then labels" || fail "AC-2 order: $n_snap $n_mut $n_edit $n_lab"

# board-ids is removed
[ ! -e "$H/board-ids" ] && pass "AC-2 board-ids is removed" || fail "AC-2 board-ids is still there"

# SNAPSHOT sets the snapshot path; the printed counts
[ -f "$snap" ] && pass "AC-2 SNAPSHOT is where the snapshot is written" || fail "AC-2 no snapshot at $snap"
[ "$(cat "$snap")" = "$(cat "$d/board.tsv")" ] && pass "AC-2 the snapshot holds item<TAB>status as read" || fail "AC-2 snapshot content: $(cat "$snap")"
assert_contains "$out" "snapshot ($snap): 5 items"
[ "$out" = "snapshot ($snap): 5 items"$'\n'"Coding: 1"$'\n'"Done: 1"$'\n'"Ready for Refinement: 1" ] && pass "AC-2 stdout is the snapshot line, then the counts per status" || fail "AC-2 stdout: $out"

# without SNAPSHOT it writes to a temp file and says where
out2="$(PATH="$d/plain:$PATH" bash "$SETUP" 2>/dev/null)"
first="$(head -1 <<< "$out2")"
case "$first" in "snapshot ("*"): 5 items") pass "AC-2 without SNAPSHOT the snapshot line still names its file" ;; *) fail "AC-2 first line without SNAPSHOT: $first" ;; esac
tmpsnap="${first#snapshot (}"; tmpsnap="${tmpsnap%%): *}"
[ -f "$tmpsnap" ] && pass "AC-2 without SNAPSHOT the named file exists" || fail "AC-2 no file at $tmpsnap"
rm -f "$tmpsnap"

# a board with no Status field stops with exit 1
printf '#!/usr/bin/env bash\ncase "$*" in "project view"*) echo PVT_x ;; "project field-list"*) ;; esac\n' > "$d/gh-nofield"; chmod +x "$d/gh-nofield"
assert_exit 1 env PATH="$d/plain:$PATH" FACTORY_GH="$d/gh-nofield" bash "$SETUP"
assert_contains "$(PATH="$d/plain:$PATH" FACTORY_GH="$d/gh-nofield" bash "$SETUP" 2>&1)" "setup-board: project acme/7 has no Status field"
finish
