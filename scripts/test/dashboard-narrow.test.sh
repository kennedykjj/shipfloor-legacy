#!/usr/bin/env bash
# At 1180px and below the Factory view is one column and the page scrolls; above it the layout is unchanged (#51).
# Static: reads the CSS of dashboard.html. Geometry (overlap, the click on Approve, the header) is checked by hand.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
css = "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", h, re.S))
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)

def match_brace(s, i):  # s[i] == "{"; index of its closing brace
    d = 0
    for j in range(i, len(s)):
        if s[j] == "{": d += 1
        elif s[j] == "}":
            d -= 1
            if d == 0: return j
    return len(s) - 1

def split_top(s, sep):
    parts, d, cur = [], 0, ""
    for ch in s:
        if ch == "(": d += 1
        elif ch == ")": d -= 1
        if ch == sep and d == 0: parts.append(cur); cur = ""
        else: cur += ch
    return parts + [cur]

def decls(body):
    out = []
    for d in split_top(body, ";"):
        if ":" not in d: continue
        k, v = d.split(":", 1)
        v = re.sub(r"\s*!important", "", " ".join(v.split()))
        out.append((k.strip().lower(), v))
    return out

def parse(text):  # -> (rules outside any @-block, [(media header, inner text)])
    rules, media, i = [], [], 0
    while True:
        o = text.find("{", i)
        if o < 0: break
        head = text[i:o].strip()
        c = match_brace(text, o)
        if head.startswith("@media"): media.append((" ".join(head.split()), text[o + 1:c]))
        elif head.startswith("@"): pass
        else:
            sels = [" ".join(x.split()) for x in split_top(head, ",") if x.strip()]
            rules.append((sels, decls(text[o + 1:c])))
        i = c + 1
    return rules, media

wide, media = parse(css)
narrow_blocks = [m for h_, m in media if re.fullmatch(r"@media \(max-width: 1180px\)", h_)]
narrow_rules = [parse(m)[0] for m in narrow_blocks]
# the narrow block is the one that sets body (the maximized inbox and Settings use the same breakpoint)
narrow = []
for rs in narrow_rules:
    if any(s == "body" for sels, _ in rs for s in sels): narrow = rs

def unmaxed(s): return " ".join(s.replace(":not(.maxed)", "").split())
def hits(rules, target):
    return [d for sels, ds in rules for s in sels if unmaxed(s) == target for d in ds]
def last(ds, prop):
    v = [x for k, x in ds if k == prop]
    return v[-1] if v else None
def overflow(ds, axis):  # axis 0 = x, 1 = y
    cur = None
    for k, v in ds:
        t = v.split()
        if k == "overflow" and t: cur = t[axis] if len(t) > 1 else t[0]
        elif k == ("overflow-x", "overflow-y")[axis]: cur = v
    return cur
def inside_panel(rules, leaf):  # rules whose last compound is `leaf` and that do not target a .maxed panel
    ds = []
    for sels, d in rules:
        for s in sels:
            u = unmaxed(s)
            if ".maxed" not in u and re.split(r"[\s>+~]+", u)[-1] == leaf: ds += d
    return ds

def ok(cond, name, why):
    print(("ok|" + name) if cond else ("FAIL|" + name + ": " + why))

if not narrow:
    print("FAIL|AC-1 the narrow @media (max-width: 1180px) block (the one that sets body) is missing")
    narrow_found = False
else:
    narrow_found = True

# AC-1: one column, in the order band, waits for you, in progress, History
cols = last(hits(narrow, ".cols"), "grid-template-columns")
ok(cols is not None and len(split_top(cols, " ")) - split_top(cols, " ").count("") == 1,
   "AC-1 narrow block: .cols is one column", f".cols grid-template-columns is {cols!r}")
ok(last(hits(narrow, ".side"), "display") == "contents",
   "AC-1 narrow block: .side is display: contents", f".side display is {last(hits(narrow, '.side'), 'display')!r}")
def order(sel):
    v = last(hits(narrow, sel), "order")
    return int(v) if v is not None and re.fullmatch(r"-?\d+", v) else None
o = [order(".yours"), order(".work"), order(".telem")]
ok(None not in o and o[0] < o[1] < o[2],
   "AC-1 narrow block: order is .yours, .work, .telem", f"order of .yours/.work/.telem is {o}")

# AC-3: the document is the vertical scroller; no cap left on the panels
b = hits(narrow, "body")
ok(last(b, "height") == "auto", "AC-3 narrow block: body has height: auto", f"body height is {last(b, 'height')!r}")
ok(overflow(b, 1) == "auto", "AC-3 narrow block: body has overflow: auto", f"body overflow-y is {overflow(b, 1)!r}")
for p in (".yours", ".work", ".telem"):
    ds = hits(narrow, p)
    mh = last(ds, "max-height")
    vh = [f"{k}: {v}" for k, v in ds if "vh" in v]
    ok(mh in (None, "none", "unset", "initial") and not vh,
       f"AC-3 narrow block: {p} has no max-height or vh cap", f"{p} max-height is {mh!r}, vh declarations {vh}")

# AC-5: #list and .tiles do not scroll on their own outside a maximized panel
for leaf in ("#list", ".tiles"):
    v = overflow(inside_panel(narrow, leaf), 1)
    ok(v == "visible", f"AC-5 narrow block: {leaf} is overflow: visible outside .maxed", f"{leaf} overflow-y is {v!r}")

# AC-6: a tile never pushes the page sideways; the band scrolls inside its own panel
t = last(inside_panel(narrow, ".tiles"), "grid-template-columns") or ""
ok("min(320px, 100%)" in t, "AC-6 narrow block: .tiles minimum is min(320px, 100%)", f".tiles grid-template-columns is {t!r}")
bx = overflow([d for sels, ds in wide + narrow for s in sels if s == ".band" for d in ds], 0)
ok(bx == "auto", "AC-6 .band keeps overflow-x: auto", f".band overflow-x is {bx!r}")

# AC-8: outside every media block the wide layout is what it was
wb = hits(wide, "body")
ok(overflow(wb, 1) == "hidden", "AC-8 wide: body is overflow: hidden", f"body overflow-y is {overflow(wb, 1)!r}")
rows = last(wb, "grid-template-rows")
ok(rows == "auto auto minmax(0, 1fr)", "AC-8 wide: body rows are auto auto minmax(0, 1fr)", f"body rows are {rows!r}")
wc = last(hits(wide, ".cols"), "grid-template-columns") or ""
ok(len([x for x in split_top(re.sub(r"\(([^()]*)\)", lambda m: "(" + m.group(1).replace(" ", "") + ")", wc), " ") if x]) == 2,
   "AC-8 wide: .cols has two columns", f".cols grid-template-columns is {wc!r}")
PY
)"
while IFS= read -r line; do
  case "$line" in
    ok\|*) pass "${line#ok|}" ;;
    FAIL\|*) fail "${line#FAIL|}" ;;
    *) fail "unexpected output: $line" ;;
  esac
done <<< "$out"
finish
