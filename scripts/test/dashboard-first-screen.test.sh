#!/usr/bin/env bash
# The Factory view's first screen: one summary line, the lifecycle band and "Today" closed until opened, "Yours" alone on top.
# AC-1 and AC-4 are pixel measures, checked by UX/UI in validation; the rest is read from the page's text.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
cat = json.load(open(sys.argv[2], encoding="utf-8"))
res = []
def check(name, cond, why):
    res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
def src(start):  # the source of a top-level function or const: up to the next line that starts at column 0 with code
    i = h.find(start)
    if i < 0: return ""
    m = re.search(r"\n(?=[A-Za-z}/])", h[i + len(start):])
    # a function body ends at its closing brace on column 0
    if start.startswith("function"):
        eol = h.find("\n", i)
        if eol > 0 and h[i:eol].rstrip().endswith("}"): return h[i:eol]  # a one-line function
        j = h.find("\n}", i)
        return h[i:j + 2] if j > 0 else h[i:]
    return h[i:i + (m.start() if m else 600) + len(start)]
def tag(attr, val):  # every opening tag that carries attr="val"
    return [t for t in re.findall(r"<[a-z][^>]*>", h) if re.search(rf'\b{attr}\s*=\s*["\']{re.escape(val)}["\']', t)]
def has(t, a): return re.search(rf"(?<![\w-]){a}(?![\w-])", t) is not None

band, today = tag("id", "band"), tag("id", "today")
sumline = tag("id", "sumline")
btn_band = [t for t in tag("data-show", "band") if t.startswith("<button")]
btn_today = [t for t in tag("data-show", "today") if t.startswith("<button")]

# AC-2: the view opens with the band and "Today" closed and one summary line
check("AC-2 the lifecycle band is hidden in the static markup", bool(band) and has(band[0], "hidden"), "nav#band is not hidden")
check("AC-2 Today is a hidden section with id=today", bool(today) and has(today[0], "hidden") and "telem" in today[0], 'section.telem has no id="today" with hidden')
check("AC-2 a summary line #sumline sits in #board before .cols", bool(sumline) and 0 <= h.find('id="sumline"') < h.find('id="cols"') and h.find('id="board"') < h.find('id="sumline"'), "div#sumline is not the first row of #board before #cols")
check("AC-2 the summary line is hidden until the first read", bool(sumline) and has(sumline[0], "hidden"), "#sumline is not hidden in the static markup")
check("AC-2 no span#sum: the sentence is gone, the header holds the figures", not tag("id", "sum"), 'an element with id="sum" is still in the page')
for nm, bt, ctl in (("band", btn_band, "band"), ("today", btn_today, "today")):
    check(f"AC-2 the {nm} button is closed and controls #{ctl}", bool(bt) and 'aria-expanded="false"' in bt[0] and f'aria-controls="{ctl}"' in bt[0], f'no button[data-show="{nm}"] with aria-expanded="false" and aria-controls="{ctl}"')
check("AC-2 the buttons say Lifecycle and Today", bool(re.search(r'<button[^>]*data-show="band"[^>]*>\s*(?:<[^>]+>\s*)*Lifecycle', h)) and bool(re.search(r'<button[^>]*data-show="today"[^>]*>\s*(?:<[^>]+>\s*)*Today', h)), "the two buttons do not read Lifecycle and Today")
check("AC-2 the state starts as S.show = {band: false, today: false}", bool(re.search(r"show\s*:\s*\{\s*band\s*:\s*false\s*,\s*today\s*:\s*false\s*\}", h)), "S.show is not declared closed")
rs = src("function renderSum")
check("AC-2 renderSum is gone", not rs and "renderSum" not in h, "function renderSum is still in the page")
check("AC-2 the summary sentence's CSS is gone", "#sum" not in h, "a #sum rule is still in the page")
rb = src("function renderBoard")
check("AC-2 renderBoard takes the panels' hidden from S.show", "S.show.band" in rb and "S.show.today" in rb, "renderBoard does not read S.show.band and S.show.today")
check("AC-2 #sumline follows #cols", "sumline" in rb, "renderBoard does not set #sumline with #cols")
check("AC-2 the board grid has a row for the line", bool(re.search(r"grid-template-rows:\s*auto\s+auto\s+minmax\(0,\s*1fr\)", h)), "the .board rows are not auto auto minmax(0, 1fr)")
check("AC-2 the line stays out of localStorage", "shipfloor.show" not in h and "localStorage" not in src("function show("), "the open state is stored")
for k, v in (("\\\\bin use\\\\b", "em uso"), ("est\\\\. spent today", "est. gastos hoje"), ("(\\\\d+) runs? today", "$1 execuções hoje")):
    want = json.loads('"' + k + '"')
    ok = any(a == want for a, b in cat["rx"])
    check("AC-2 pt-BR summary-line rx " + ascii(v) + " is removed", not ok, "rx entry " + ascii(want) + " is still in the catalog")

# AC-3: a control opens and closes in place, and the state survives the refresh
sh = src("function show(")
check("AC-3 show(which, on) exists", bool(sh), "function show(which, on) is missing")
check("AC-3 show sets aria-expanded on the button", "aria-expanded" in sh, "show does not set aria-expanded")
check("AC-3 show sets the panel's hidden and S.show", "hidden" in sh and "S.show" in sh, "show does not set hidden and S.show")
check("AC-3 show restores a maximized panel first", "maxed" in sh, "show does not restore a maximized panel")
check("AC-3 closing the band closes the peek", "peek" in sh.lower(), "show does not close an open peek")
check("AC-3 show has no sentence to re-render", "renderSum" not in sh, "show still calls renderSum")
check("AC-3 the click handler has a [data-show] branch that toggles", bool(re.search(r"\[data-show\]", h)) and bool(re.search(r"dataset\.show", h)) and bool(re.search(r"show\(\s*[\w.]*dataset\.show\s*,\s*!", h)), "no [data-show] branch toggling through show()")
check("AC-3 a refresh never rewrites the buttons", "data-show" not in rb and "data-show" not in rs and 'getElementById("sumline").innerHTML' not in h and 'setHTML($("sumline")' not in h, "renderBoard/renderSum touch the data-show buttons or #sumline")
check("AC-3 renderTelem returns early while Today is closed", bool(re.search(r"S\.show\.today", src("function renderTelem"))), "renderTelem does not look at S.show.today")

# AC-7: nothing waits
ry = src("function renderYours")
check("AC-7 the page's empty list renders no li.empty paragraph", 'class="empty"' not in ry and "The factory moves on its own" not in ry, "renderYours still renders li.empty in the page")
em = re.search(r"w\.map\(passHtml\)\.join\(\s*(?:\"\"|'')\s*\)(\s*:\s*(?:\"\"|''|``))?", ry)
check("AC-7 with nothing waiting #list gets an empty string", bool(em) and (em.group(1) is not None or "w.length ?" not in ry), "renderYours does not set #list to an empty string when nothing waits")
check("AC-7 the key hints are hidden when nothing waits", bool(re.search(r"foot", ry)) and bool(re.search(r"hidden", ry)), "renderYours does not hide .foot")
check("AC-7 the heading still says Nothing waits for you", "Nothing waits for you" in ry, "the heading string is gone")
ri = src("function renderInbox")
check("AC-7 the maximized inbox keeps its own empty text", bool(re.search(r"""setHTML\(\$\("ir"\),\s*['"]<p class="empty">Nothing waits for you\. Cards show up here""", ri)), "renderInbox no longer writes the p.empty 'Nothing waits for you. Cards show up here...' into #ir")

# AC-8: more than 5 wait, the oldest first
wt = src("const waiting")
wt = wt[:wt.find("\n\n")] if "\n\n" in wt else wt
check("AC-8 waiting() sorts by since", "sort" in wt and "since" in wt, "waiting() does not sort the oldest wait first")
check("AC-8 cards without since go last", bool(re.search(r'since\s*\|\|\s*"~"', wt)), 'waiting() does not put cards without since last (since || "~")')
ib = re.search(r"const inboxCards = .*", h)
check("AC-8 inboxCards keeps only its gone filter", bool(ib) and "sort" not in ib.group(0) and "gone" in ib.group(0), "inboxCards still sorts")
check("AC-8 Yours keeps the total in the heading", "wait" in ry and "w.length" in ry, "the total is gone")
# AC-2 has the most checks; print it last so the red gate's first 20 failing lines show AC-3, AC-7 and AC-8 too
print("\n".join(sorted(res, key=lambda r: "AC-2" in r)))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
