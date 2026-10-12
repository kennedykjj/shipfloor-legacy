#!/usr/bin/env bash
# Every theme of the dashboard sets the same tokens as the base one, keeps its text readable, and is offered in Settings.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
blocks = {n: dict(re.findall(r"--([a-z0-9-]+):\s*([^;]+);", b)) for n, b in re.findall(r'\[data-theme="([a-z]+)"\]\s*\{([^}]*)\}', h)}
offered = set(re.findall(r'\["([a-z]+)", "[^"]+"\]', h[h.index("const THEMES"):h.index("const THEMES") + 900]))
base = blocks["charcoal"]
colors = [k for k, v in base.items() if re.fullmatch(r"#[0-9a-fA-F]{6}", v)]
def lum(c):
    v = [int(c[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    v = [x / 12.92 if x <= .03928 else ((x + .055) / 1.055) ** 2.4 for x in v]
    return .2126 * v[0] + .7152 * v[1] + .0722 * v[2]
bad = []
if offered - {"auto"} != set(blocks): bad.append(f"settings offers {sorted(offered)} but the css has {sorted(blocks)}")
for name, t in blocks.items():
    missing = [k for k in colors if not re.fullmatch(r"#[0-9a-fA-F]{6}", t.get(k, ""))]
    if missing: bad.append(f"{name}: missing {missing}"); continue
    for fg in "text soft muted faint sand ok warn bad refine".split():
        for bg in ("ground", "panel", "panel-hi"):
            a, b = sorted((lum(t[fg]), lum(t[bg])), reverse=True)
            if (a + .05) / (b + .05) < 4.5: bad.append(f"{name}: {fg} on {bg} is {(a + .05) / (b + .05):.2f}:1")
    if (lum(t["ground"]) > .5) != ("color-scheme: light" in h[h.index(f'[data-theme="{name}"]'):].split("}")[0]): bad.append(f"{name}: color-scheme does not match its ground")
print(len(blocks), "themes"); print("\n".join(bad) or "all readable")
PY
)"
assert_contains "$out" "12 themes"
assert_contains "$out" "all readable"

# Settings offers four themes first and the rest behind "More themes" (AC-5), and says which is in use when it is behind the fold (AC-6).
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
cat = json.load(open(sys.argv[2], encoding="utf-8"))
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
i = h.index("const THEMES"); win = h[i:i + 900]
pos = {k: win.find(k + ":") for k in ("first", "dark", "light")}
def ids(k):
    if pos[k] < 0: return []
    later = sorted(p for p in pos.values() if p > pos[k])
    return re.findall(r'\["([a-z]+)", "[^"]+"\]', win[pos[k]:later[0] if later else len(win)])
first, dark, light = ids("first"), ids("dark"), ids("light")
css = set(re.findall(r'\[data-theme="([a-z]+)"\]\s*\{', h))
check("AC-5 THEMES.first holds Auto, Floor tape, Kraft, High contrast in that order", first == ["auto", "tape", "kraft", "contrast"], f"first is {first}")
rest = dark + light
check("AC-5 dark and light keep the other nine themes, none of the four", len(rest) == 9 and not set(rest) & set(first), f"dark+light are {rest}")
check("AC-5 each of the twelve themes is offered once", sorted(x for x in first + rest if x != "auto") == sorted(css) and len(css) == 12, f"offered {sorted(first + rest)}")
check("AC-5 More themes fold is labelled", "More themes" in h, 'the text "More themes" is missing')
check("AC-5 the fold is a data-fold=themes button with aria-expanded and aria-controls", bool(re.search(r'<button[^>]*data-fold="themes"', h)) and bool(re.search(r'<button[^>]*data-fold="themes"[^>]*aria-expanded=', h) or re.search(r'<button[^>]*aria-expanded=[^>]*data-fold="themes"', h)) and bool(re.search(r'<button[^>]*data-fold="themes"[^>]*aria-controls=', h) or re.search(r'<button[^>]*aria-controls=[^>]*data-fold="themes"', h)), 'no button[data-fold="themes"] with aria-expanded and aria-controls')
check("AC-5 SET.moreThemes starts closed", bool(re.search(r"moreThemes\s*:\s*false", h)), "SET has no moreThemes: false")
check("AC-5 Settings opens with the fold closed", len(re.findall(r"moreThemes\s*=\s*false", h)) >= 1, "nothing resets SET.moreThemes to false")
b = re.search(r'(?:fold|\bk)\s*===?\s*"themes"', h)
seg = h[b.start():b.start() + 500] if b else ""
check("AC-5 a themes branch toggles SET.moreThemes", bool(b) and "moreThemes" in seg, 'no data-fold="themes" branch in the click handler')
check("AC-5 the themes fold is not saved in shipfloor.shut", bool(b) and "shipfloor.shut" not in seg.split("}")[0],"the themes branch writes shipfloor.shut")
tp = re.search(r"else if \(t\.dataset\.themePick\).*", h)
check("AC-5 picking a theme keeps focus on its swatch", bool(tp) and "focus" in tp.group(0), "the theme-pick branch does not refocus the swatch")
check("AC-5 the first group has no heading", bool(re.search(r"THEMES\.first", h)), "Settings does not draw THEMES.first")
check("AC-6 the fold row says In use: with the theme name in <b>", bool(re.search(r"In use: <b>", h)), 'the text "In use: <b>name</b>" is missing')
check("AC-6 In use shows only when the theme is not one of the four", bool(re.search(r"THEMES\.first", h)) and bool(re.search(r"In use: <b>", h)) and bool(re.search(r"first[^;\n]*(some|includes|find|map)[^;\n]*THEME|THEME[^;\n]*first", h)), "In use is not conditioned on THEME being outside THEMES.first")
check("AC-6 pt-BR In use: prefix", any(a == "^In use: " and b == "Em uso: " for a, b in cat["rx"]), "rx '^In use: ' is missing")
check("AC-5 pt-BR More themes", cat["exact"].get("More themes") == "Mais temas", "exact 'More themes' is missing")
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"

# The decision column's well and the Approve pill's hover keep 4.5:1 in every theme (#120, AC-5).
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
blocks = {n: dict(re.findall(r"--([a-z0-9-]+):\s*([^;]+);", b)) for n, b in re.findall(r'\[data-theme="([a-z]+)"\]\s*\{([^}]*)\}', h)}
base = blocks["charcoal"]
css = re.sub(r"/\*.*?\*/", "", h[h.index("<style>") + 7:h.index("</style>")], flags=re.S)
css = re.sub(r"@font-face\s*\{[^}]*\}", "", css)
rules = [(re.sub(r"\s+", " ", s).strip(), b) for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", css)]
def decl(sel_ok, prop):
    for s, b in rules:
        if sel_ok(s):
            m = re.search(r"(?<![\w-])%s\s*:\s*([^;}]+)" % prop, b)
            if m: return m.group(1).replace("!important", "").strip()
    return ""
def split_args(s):
    out, d, cur = [], 0, ""
    for ch in s:
        if ch == "(": d += 1
        if ch == ")": d -= 1
        if ch == "," and d == 0: out.append(cur.strip()); cur = ""
        else: cur += ch
    return out + [cur.strip()]
def resolve(v, tok, depth=0):
    """-> (r, g, b, a) with channels 0-255 and alpha 0-1; raises ValueError on a value it cannot resolve."""
    v = v.strip()
    m = re.fullmatch(r"#([0-9a-fA-F]+)", v)
    if m and len(m.group(1)) in (3, 4, 6, 8):
        x = m.group(1)
        if len(x) < 6: x = "".join(c * 2 for c in x)
        a = int(x[6:8], 16) / 255 if len(x) == 8 else 1.0
        return (int(x[0:2], 16), int(x[2:4], 16), int(x[4:6], 16), a)
    m = re.fullmatch(r"var\(\s*--([a-z0-9-]+)\s*\)", v)
    if m and depth < 5 and tok(m.group(1)): return resolve(tok(m.group(1)), tok, depth + 1)
    m = re.fullmatch(r"color-mix\((.*)\)", v)
    if m:
        a = split_args(m.group(1))
        if len(a) == 3 and re.fullmatch(r"in\s+srgb", a[0]):
            parts = []
            for c in a[1:]:
                pm = re.fullmatch(r"(.*?)\s+(\d*\.?\d+)%", c)
                parts.append((pm.group(1), float(pm.group(2))) if pm else (c, None))
            (c1, p1), (c2, p2) = parts
            if p1 is None and p2 is None: p1 = p2 = 50.0
            elif p1 is None: p1 = 100 - p2
            elif p2 is None: p2 = 100 - p1
            x, y = resolve(c1, tok, depth + 1), resolve(c2, tok, depth + 1)
            w1, w2 = p1 / (p1 + p2), p2 / (p1 + p2)
            return tuple(i * w1 + j * w2 for i, j in zip(x, y))
    raise ValueError(v)
def rgb(c): return list(c[:3])
def lum(v):
    v = [x / 255 for x in v]
    v = [x / 12.92 if x <= .03928 else ((x + .055) / 1.055) ** 2.4 for x in v]
    return .2126 * v[0] + .7152 * v[1] + .0722 * v[2]
def ratio(a, b):
    x, y = sorted((lum(a), lum(b)), reverse=True)
    return (x + .05) / (y + .05)
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
for name, t in sorted(blocks.items()):
    tok = lambda k: t.get(k, base.get(k, "")).strip()   # a theme that omits a token inherits the base one
    # what the page's own rules paint: the .idec background, and the pill's hover background under the pill's text color
    idec_bg = decl(lambda s: s == ".idec", "background")
    try:
        c = resolve(idec_bg, tok)
        panel = rgb(resolve(tok("panel"), tok))
        under = [x * (1 - c[3]) + y * c[3] for x, y in zip(panel, c[:3])]
        for fg in ("text", "soft", "muted"):
            r = ratio(rgb(resolve(tok(fg), tok)), under)
            check(f"AC-5 {name}: {fg} on the .idec background is 4.5:1", r >= 4.5, f"{fg} on .idec background {idec_bg} over panel is {r:.2f}:1")
    except ValueError:
        check(f"AC-5 {name}: the .idec background resolves", False, f"cannot resolve the .idec background {idec_bg or 'missing'}")
    hov_bg = decl(lambda s: ".pill:hover" in s, "background")
    pill_fg = decl(lambda s: s == ".stub .pill, .edit .pill", "color")
    try:
        fill = resolve(hov_bg, tok)
        r = ratio(rgb(resolve(pill_fg, tok)), rgb(fill))
        check(f"AC-5 {name}: the pill's text {pill_fg} on its hover background is 4.5:1", r >= 4.5, f"{pill_fg} text on the pill's hover background {hov_bg} is {r:.2f}:1")
    except ValueError as e:
        check(f"AC-5 {name}: the pill's hover colors resolve", False, f"cannot resolve the pill's hover background {hov_bg or 'missing'} or its text color {pill_fg or 'missing'}")
check("AC-5 twelve themes are checked", len(blocks) == 12, f"{len(blocks)} themes")
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
