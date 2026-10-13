#!/usr/bin/env bash
# A card blocked for the owner taken back (#127): dashboard.html and the pt-BR catalog read as text, no browser.
# The gestures (drag, M + digit, the box's Move and Cancel) are checked by hand in review.
#   AC-1  a card blocked for the owner can be held; its lit columns come from the overview's take_back, never its own
#         column, each with what dropping there means; the drop opens the box, which posts to take-back
#   AC-8  "Unblock & retry" stays on the pass and in the block note; the new strings are in pt-BR, column names in English
source "$(dirname "$0")/lib.sh"
PY=python3; $PY -c '' 2>/dev/null || PY=python
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
page="$(cat "$FACTORY_DIR/dashboard.html")"
has() { case "$page" in *"$2"*) pass "$1" ;; *) fail "$1 (missing: $2)" ;; esac; }

# AC-1
has "AC-1 the lit columns come from the overview's take_back" 'S.overview?.take_back?.[c.column] || S.overview?.take_back?.["*"]'
has "AC-1 a card is never taken back to its own column" '.filter((to) => to !== c.column)'
has "AC-1 only a card blocked for the owner is taken back" 'c.blocked === "owner" ? (S.overview?.take_back'
has "AC-1 a card locked as blocked can be held when it has somewhere to go" 'c.lock === "blocked" ? takeOf(c).length > 0'
has "AC-1 Ready for Dev means redoing the code" '"Ready for Dev": "redo the code from the approved spec"'
has "AC-1 Ready for Refinement means refining the spec again" '"Ready for Refinement": "refine the spec again"'
has "AC-1 Inbox means taking it out of the factory" '"Inbox": "take it out of the factory"'
has "AC-1 a drop opens the box in its take-back form" 'if (t.take) { renderBoard(); return openBox({ key: h.key, from: h.from, to, take: true }); }'
has "AC-1 the box posts to take-back" '/take-back`'
has "AC-1 the box's button is Move" '$("mgo").textContent = b.take ? "Move"'
has "AC-1 an empty comment is accepted: Move is never disabled" 'if (L.box?.take) { $("mgo").disabled = false;'
has "AC-1 a drop on the Inbox says the pull request is closed and the branch kept" '"An open pull request is closed; its branch is kept."'
has "AC-1 a held blocked card is not reordered in its own column" 'const queue = (h) => !h.take && ordered(h.from);'
has "AC-7 a card blocked by infrastructure keeps its lock" '(movesOf(c.column).length > 0 || c.lock === "infra") && c.lock'

# AC-8: Unblock & retry stays where it was
has "AC-8 the pass keeps Unblock & retry" '<button class="pill" data-q="unblock">Unblock &amp; retry</button>'
has "AC-8 the block note keeps Unblock & retry" '<button class="btn" data-unblock>Unblock &amp; retry</button>'

# AC-8: the new strings are in the pt-BR catalog, and none of them names a column in Portuguese
CAT="$FACTORY_DIR/lang/dashboard.pt-BR.json"
if $PY -I -c '
import json, re, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
want = ["redo the code from the approved spec", "refine the spec again", "take it out of the factory",
        "? A comment is optional; it is posted on the issue.", "An open pull request is closed; its branch is kept.",
        "; its pull request was closed. The board confirms it on the dispatcher\x27s next read.", "Move"]
miss = [w for w in want if w not in cat["exact"]]
rx = dict((k, v) for k, v in cat["rx"])
if "^Move #(\\d+) to $" not in rx: miss.append("^Move #(\\d+) to $")
bad = [v for v in [cat["exact"].get(w, "") for w in want] + [rx.get("^Move #(\\d+) to $", "")] if re.search(r"Pronto para|Entrada\b", v)]
print("missing:", miss, "column names translated:", bad); sys.exit(1 if miss or bad else 0)' "$(nat "$CAT")"; then
  pass "AC-8 the new strings are in pt-BR, column names kept in English"
else fail "AC-8 the pt-BR catalog"; fi
# the box heading and the toast name the column through cn(), which the catalog never rewrites
has "AC-8 the box heading keeps the column name in English" '<span>Move #${n} to </span>${cn(b.to)}'
finish
