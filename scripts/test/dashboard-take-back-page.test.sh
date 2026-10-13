#!/usr/bin/env bash
# A card blocked for the owner taken back (#127): dashboard.html and the pt-BR catalog read as text, no browser.
# The gestures (drag, M + digit, the box's Move and Cancel) are checked by hand in review.
#   AC-1  a card blocked for the owner can be held; its lit columns come from the overview's take_back, never its own
#         column, each with what dropping there means; the drop opens the box, which posts to take-back
#   AC-8  "Unblock & retry" stays on the pass and in the block note; the new strings are in pt-BR, column names in English
source "$(dirname "$0")/lib.sh"
PY=python3; $PY -c '' 2>/dev/null || PY=python
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
page="$(cat "$FACTORY_DIR/dashboard.html")"; text="$(page_english)"  # the page's words are a catalog by key (#122)
says() { case "$text" in *"$2"*) pass "$1" ;; *) fail "$1 (missing: $2)" ;; esac; }
has() { case "$page" in *"$2"*) pass "$1" ;; *) fail "$1 (missing: $2)" ;; esac; }

# AC-1
has "AC-1 the lit columns come from the overview's take_back" 'S.overview?.take_back?.[c.column] || S.overview?.take_back?.["*"]'
has "AC-1 a card is never taken back to its own column" '.filter((to) => to !== c.column)'
has "AC-1 only a card blocked for the owner is taken back" 'c.blocked === "owner" ? (S.overview?.take_back'
has "AC-1 a card locked as blocked can be held when it has somewhere to go" 'c.lock === "blocked" ? takeOf(c).length > 0'
has "AC-1 each column a card is taken back to has its meaning" 'const TAKE = { "Ready for Dev": "take.redo", "Ready for Refinement": "take.refine", "Inbox": "take.out" };'
[ "$(en_msg take.redo)" = "redo the code from the approved spec" ] && pass "AC-1 Ready for Dev means redoing the code" || fail "AC-1 take.redo is $(en_msg take.redo)"
[ "$(en_msg take.refine)" = "refine the spec again" ] && pass "AC-1 Ready for Refinement means refining the spec again" || fail "AC-1 take.refine is $(en_msg take.refine)"
[ "$(en_msg take.out)" = "take it out of the factory" ] && pass "AC-1 Inbox means taking it out of the factory" || fail "AC-1 take.out is $(en_msg take.out)"
has "AC-1 a drop opens the box in its take-back form" 'if (t.take) { renderBoard(); return openBox({ key: h.key, from: h.from, to, take: true }); }'
has "AC-1 the box posts to take-back" '/take-back`'
has "AC-1 the box's button is Move" '$("mgo").textContent = t(b.take ? "chip.move"'
[ "$(en_msg chip.move)" = Move ] && pass "AC-1 chip.move is Move" || fail "AC-1 chip.move is $(en_msg chip.move)"
has "AC-1 an empty comment is accepted: Move is never disabled" 'if (L.box?.take) { $("mgo").disabled = false;'
says "AC-1 a drop on the Inbox says the pull request is closed and the branch kept" '"An open pull request is closed; its branch is kept."'
has "AC-1 a held blocked card is not reordered in its own column" 'const queue = (h) => !h.take && ordered(h.from);'
has "AC-7 a card blocked by infrastructure keeps its lock" '(movesOf(c.column).length > 0 || c.lock === "infra") && c.lock'

# AC-8: Unblock & retry stays where it was
says "AC-8 the pass keeps Unblock & retry" '<button class="pill" data-q="unblock">Unblock & retry</button>'
says "AC-8 the block note keeps Unblock & retry" '<button class="btn" data-unblock>Unblock & retry</button>'

# AC-8: the new strings are in the pt-BR catalog, and none of them names a column in Portuguese
CAT="$FACTORY_DIR/lang/dashboard.pt-BR.json"
if $PY -I -c '
import json, re, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
want = ["take.redo", "take.refine", "take.out", "box.take", "box.take.inbox", "take.moved_pr", "chip.move"]  # by key since #122
miss = [w for w in want if not cat["messages"].get(w)]
bad = [cat["messages"].get(w, "") for w in want if re.search(r"Pronto para|Entrada\b", cat["messages"].get(w, ""))]
print("missing:", miss, "column names translated:", bad); sys.exit(1 if miss or bad else 0)' "$(nat "$CAT")"; then
  pass "AC-8 the new strings are in pt-BR, column names kept in English"
else fail "AC-8 the pt-BR catalog"; fi
# the box heading and the toast name the column through cn(), which the catalog never rewrites
has "AC-8 the box heading keeps the column name in English" 't("box.take", { n, column: cn(b.to) })'
finish
