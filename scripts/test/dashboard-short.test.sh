#!/usr/bin/env bash
# Factory view above 1180px, Lifecycle and Today open on a short window: the list keeps its first two cards, Today gives way
# and scrolls inside itself, "In progress" scrolls inside its panel (#112).
# Static: reads the CSS and the script of dashboard.html. AC-1, AC-2 and AC-8 are pixel measures taken by UX/UI in validation.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
css = "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", h, re.S))
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
js = "\n".join(re.findall(r"<script[^>]*>(.*?)</script>", h, re.S))

def match_brace(s, i):
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
    res = []
    for d in split_top(body, ";"):
        if ":" not in d: continue
        k, v = d.split(":", 1)
        v = re.sub(r"\s*!important", "", " ".join(v.split()))
        res.append((k.strip().lower(), v))
    return res

def parse(text):
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
narrow = []
for h_, m in media:
    if re.fullmatch(r"@media \(max-width: 1180px\)", h_):
        rs = parse(m)[0]
        if any(s == "body" for sels, _ in rs for s in sels): narrow = rs

def hits(rules, target):
    return [d for sels, ds in rules for s in sels if s == target for d in ds]
def last(ds, prop):
    v = [x for k, x in ds if k == prop]
    return v[-1] if v else None
def overflow_y(ds):
    cur = None
    for k, v in ds:
        t = v.split()
        if k == "overflow" and t: cur = t[1] if len(t) > 1 else t[0]
        elif k == "overflow-y": cur = v
    return cur
def shrink(ds):
    cur = None
    for k, v in ds:
        t = v.split()
        if k == "flex" and t:
            if t[0] == "none": cur = 0.0
            elif t[0] == "auto": cur = 1.0
            elif len(t) > 1 and re.fullmatch(r"\d+(\.\d+)?", t[1]): cur = float(t[1])
            elif re.fullmatch(r"\d+(\.\d+)?", t[0]): cur = 1.0
        elif k == "flex-shrink" and re.fullmatch(r"\d+(\.\d+)?", v): cur = float(v)
    return cur
def mask_px(rules, pred):  # the bottom-fade sizes carried by the rules whose selector satisfies pred
    px = set()
    for sels, ds in rules:
        for s in sels:
            if pred(s):
                for k, v in ds:
                    if "mask" in k:
                        px.update(int(x) for x in re.findall(r"calc\(\s*100%\s*-\s*(\d+)px\s*\)", v))
    return px

def fnsrc(name):  # source of `function name(` or `const name =`, up to its closing brace on column 0 (or its own line)
    m = re.search(r"(?:^|\n)[ \t]*(?:async\s+)?function\s+" + name + r"\s*\(", js) or re.search(r"(?:^|\n)[ \t]*(?:const|let|var)\s+" + name + r"\s*=", js)
    if not m: return ""
    i = m.start()
    eol = js.find("\n", m.end())
    first = js[m.end():eol if eol > 0 else len(js)].rstrip()
    if first.endswith("}") or first.endswith("};") or first.endswith(";"):
        if first.count("{") <= first.count("}"): return js[i:eol if eol > 0 else len(js)]
    j = js.find("\n}", m.end())
    return js[i:j + 2] if j > 0 else js[i:]

def branch_n():  # the statement the key handler runs for the N key
    m = re.search(r"if\s*\(\s*k\s*===?\s*[\"']n[\"']\s*\)", js)
    if not m: return ""
    i, rest = m.end(), js[m.end():]
    s = rest.lstrip()
    if s.startswith("{"):
        o = m.end() + (len(rest) - len(s))
        return js[m.start():match_brace(js, o) + 1]
    e = [x for x in (rest.find("const hit"), rest.find("\n});")) if x >= 0]
    return js[m.start():i + (min(e) if e else 400)]

def ok(cond, name, why):
    print(("ok|" + name) if cond else ("FAIL|" + name + ": " + why))

fit = fnsrc("fit")
def refs(src, ident):  # the source mentions the element by id
    return re.search(r"[\"']#?" + ident + r"[\"']|#" + ident + r"\b", src) is not None
def listens(ident):  # a scroll listener on the element whose handler is fit
    for line in js.split("\n"):
        if re.search(r"addEventListener\(\s*[\"']scroll[\"']", line) and re.search(r"\bfit\b", line) and refs(line, ident): return True
    return bool(re.search(r"[\"']" + ident + r"[\"']\s*\)\s*\??\.addEventListener\(\s*[\"']scroll[\"']\s*,[^;]*\bfit\b", js))

# AC-3: Today takes only the height the list leaves and scrolls inside itself; the page does not scroll
telem = hits(wide, ".telem")
sh = shrink(telem)
ok(sh is not None and sh > 0, "AC-3 wide: .telem can shrink (flex-shrink is not 0)", ".telem flex-shrink is %r" % sh)
mh = last(telem, "min-height") or ""
px = re.fullmatch(r"(\d+(?:\.\d+)?)px", mh)
ok(bool(px) and 60 <= float(px.group(1)) <= 120, "AC-3 wide: .telem min-height is a floor of about 100px, not 292px", ".telem min-height is %r" % mh)
ok(last(telem, "max-height") == "60%", "AC-3 wide: .telem keeps max-height: 60%", ".telem max-height is %r" % last(telem, "max-height"))
ok(overflow_y(telem) == "auto", "AC-3 wide: .telem scrolls inside itself (overflow-y: auto)", ".telem overflow-y is %r" % overflow_y(telem))
tm = mask_px(wide, lambda s: s.endswith(".cut") and ("telem" in s or "today" in s))
ok(24 in tm, "AC-3 wide: .telem.cut carries a bottom mask of 24px", "no .telem.cut rule with a 24px bottom mask (found %s)" % sorted(tm))
ok(overflow_y(hits(wide, "body")) == "hidden", "AC-3 wide: body stays overflow: hidden (the page does not scroll)", "body overflow-y is %r" % overflow_y(hits(wide, "body")))
ok(bool(fit) and refs(fit, "today") and "cut" in fit, "AC-3 fit toggles cut on #today", "function fit is missing or does not toggle cut on #today" if not fit else "fit does not toggle cut on #today")
ok(listens("today"), "AC-3 #today has a scroll listener that calls fit", "no scroll listener on #today calls fit")

# AC-4: every waiting card can be reached and brought whole into view
lst = hits(wide, "#list")
ok(overflow_y(lst) == "auto", "AC-4 wide: #list scrolls inside itself (overflow-y: auto)", "#list overflow-y is %r" % overflow_y(lst))
lm = mask_px(wide, lambda s: s == "#list.cut")
ok(44 in lm, "AC-4 wide: #list.cut carries the 44px bottom fade", "#list.cut mask sizes are %s" % sorted(lm))
nb = branch_n()
ok(bool(nb) and "focus(" in nb, "AC-4 the N key focuses the next .ptitle", "the N branch of the key handler was not found or does not focus")
ok(bool(nb) and bool(re.search(r"scrollTop\s*(=[^=]|\+=|-=)", nb[nb.find("focus("):] if "focus(" in nb else "")),
   "AC-4 the N key sets the list's scrollTop after focusing, from the card's position", "the N branch does not write scrollTop after focus(), so the next card can stay under the fade or out of view")
ok(bool(fit) and not re.search(r"scrollTop\s*(=[^=]|\+=|-=)|scrollTo\(|scrollBy\(|scrollIntoView", fit), "AC-4 fit never writes scrollTop", "function fit is missing" if not fit else "fit moves the scroll")
ok(bool(fit) and ".focus(" not in fit, "AC-4 fit never moves focus", "function fit is missing" if not fit else "fit calls focus")
ok(listens("list"), "AC-4 #list has a scroll listener that calls fit", "no scroll listener on #list calls fit")

# AC-5: the list floor is its first two cards as rendered, never more than its content
lmh = last(lst, "min-height") or ""
ok(re.fullmatch(r"var\(\s*--two\s*,\s*0(px)?\s*\)", lmh) is not None, "AC-5 wide: #list has min-height: var(--two, 0px)", "#list min-height is %r" % lmh)
ok(bool(fit) and "--two" in fit and ("setProperty" in fit or "style" in fit), "AC-5 fit sets --two on #list", "function fit is missing or never sets --two" if not fit else "fit does not set --two")
ok(bool(fit) and ".pass" in fit and bool(re.search(r"offsetTop|offsetHeight|getBoundingClientRect|scrollHeight", fit)), "AC-5 fit measures the rendered .pass cards", "fit does not measure the .pass elements" if fit else "function fit is missing")
ok(bool(fit) and bool(re.search(r"\[\s*1\s*\]|\.at\(\s*1\s*\)|nth-(child|of-type)\(\s*2|slice\(\s*0\s*,\s*2\s*\)|Math\.min\(\s*1\b|length\s*>\s*1|length\s*<\s*2", fit)), "AC-5 fit takes the second card, or the first when one waits", "fit does not pick the second .pass (or the first when only one)" if fit else "function fit is missing")
ok(bool(fit) and "0px" in fit, "AC-5 fit sets --two to 0px when no card waits", "fit has no 0px floor for an empty list" if fit else "function fit is missing")

# AC-6: In progress keeps a tile whole and scrolls the rest inside its panel
ok(overflow_y(hits(wide, ".tiles")) == "auto", "AC-6 wide: .tiles scrolls inside the panel (overflow-y: auto)", ".tiles overflow-y is %r" % overflow_y(hits(wide, ".tiles")))
tl = mask_px(wide, lambda s: s.endswith(".cut") and "tiles" in s)
ok(44 in tl, "AC-6 wide: .tiles.cut carries the 44px bottom fade", "no .tiles.cut rule with a 44px bottom mask (found %s)" % sorted(tl))
ok(bool(fit) and refs(fit, "tiles") and "cut" in fit, "AC-6 fit toggles cut on #tiles", "function fit is missing or does not toggle cut on #tiles" if not fit else "fit does not toggle cut on #tiles")
ok(listens("tiles"), "AC-6 #tiles has a scroll listener that calls fit", "no scroll listener on #tiles calls fit")
rw = fnsrc("renderWork").rstrip()
tail = rw[:-1].rstrip() if rw.endswith("}") else rw
ok(bool(rw) and bool(re.search(r"\bfit\s*\(", tail[-160:])), "AC-6 renderWork ends in a call to fit", "renderWork does not end with fit()" if rw else "function renderWork is missing")

# AC-7: only .side.tight compacts, only with Today open; narrow block and .maxed win; both closed is the old layout
st = [(s, ds) for sels, ds in wide for s in sels if s.startswith(".side.tight")]
ok(any(last(ds, "gap") == "10px" or last(ds, "row-gap") == "10px" for s, ds in st if s == ".side.tight"), "AC-7 wide: .side.tight sets the 10px gap", "no .side.tight rule with gap: 10px")
ok(any("foot" in s and last(ds, "display") == "none" for s, ds in st), "AC-7 wide: .side.tight hides the foot of Yours", "no .side.tight rule hides .yours .foot")
ok(any(re.search(r"h2|h3|first", s) and ((last(ds, "margin-top") == "6px") or (last(ds, "margin") or "").split()[:1] == ["6px"]) for s, ds in st), "AC-7 wide: .side.tight sets the first sub-heading's top margin to 6px", "no .side.tight rule sets a 6px top margin on Today's first sub-heading")
stray = [s for sels, ds in wide for s in sels if re.search(r"\.foot$", s) and "[hidden]" not in s and ".maxed" not in s and ".tight" not in s and last(ds, "display") == "none"]
ok(not stray, "AC-7 wide: nothing outside .side.tight hides the foot of Yours", "these rules hide the foot: %s" % stray)
ok(bool(fit) and "tight" in fit and bool(re.search(r"S\.show\.today|today[\"']\)\s*\.hidden|today\.hidden|\.telem[^;\n]*hidden", fit)), "AC-7 fit turns .tight on only when Today is open", "function fit is missing" if not fit else "fit does not toggle .tight on the column under the condition that Today is open")
ok(bool(fit) and bool(re.search(r"\.side|[\"']side[\"']", fit)) and "tight" in fit, "AC-7 fit puts .tight on .side", "function fit is missing" if not fit else "fit does not put .tight on .side")
sj = fnsrc("show").rstrip()
fi = [m.start() for m in re.finditer(r"\bfit\s*\(", sj)]
rs = sj.rfind("renderSum(")
ok(bool(sj) and bool(fi) and rs >= 0 and fi[-1] > rs, "AC-7 show calls fit after both branches (open and close)", "show does not call fit after renderBoard / renderSum" if sj else "function show is missing")
fade_names = re.findall(r"\bfade\b", js)
ok(not fade_names, "AC-7 the function fade is gone and nothing calls it", "the script still mentions fade (%d times); fit replaces it" % len(fade_names))
nar = lambda p: [d for sels, ds in narrow for s in sels if p(s) for d in ds]
floor_reset = last(nar(lambda s: re.sub(r":not\(\.maxed\)", "", s).strip().endswith("#list") and ".maxed" not in re.sub(r":not\(\.maxed\)", "", s)), "min-height")
ok(floor_reset in ("0", "0px", "auto", "none", "unset", "initial") or bool(re.search(r"innerWidth|matchMedia|1180", fit)), "AC-7 narrow block: #list has no --two floor", "the narrow block leaves #list min-height at %r" % floor_reset)
nt = bool(nar(lambda s: ".tight" in s)) or bool(re.search(r"innerWidth|matchMedia|1180", fit))
ok(nt, "AC-7 narrow block: .tight has no effect at 1180px and below", "neither the narrow block nor fit turns .tight off there")
nm = bool(nar(lambda s: ".cut" in s and ("telem" in s or "tiles" in s or "today" in s))) or bool(re.search(r"innerWidth|matchMedia|1180", fit))
ok(nm, "AC-7 narrow block: no new mask on .telem.cut / .tiles.cut at 1180px and below", "neither the narrow block nor fit turns the new masks off there")
mx = [s for sels, ds in wide for s in sels if s.endswith(".cut") and ("telem" in s or "tiles" in s)]
ok(bool(mx) and (all(":not(.maxed)" in s for s in mx) or any(".maxed" in s for sels, ds in wide for s in sels if ".cut" in s and ("telem" in s or "tiles" in s)) or "maxed" in fit),
   "AC-7 a .maxed panel gets no new mask", "the .telem.cut / .tiles.cut rules are missing, or reach a .maxed panel")
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
