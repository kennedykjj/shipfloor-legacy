#!/usr/bin/env bash
# Every theme of the dashboard sets the same tokens as the base one, keeps its text readable, and is offered in Settings.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
blocks = {n: dict(re.findall(r"--([a-z0-9-]+):\s*([^;]+);", b)) for n, b in re.findall(r'\[data-theme="([a-z]+)"\]\s*\{([^}]*)\}', h)}
offered = set(re.findall(r'"([a-z]+)"', h[h.index("const THEMES"):h.index("\n", h.index("const THEMES"))]))  # ids; each named by theme.<id> (#122)
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

# AC-1 (#180): every theme, the base one included, defines the five tokens of the v4 system; text is readable on raise and paper too
NEW = ["raise", "accent-ink", "paper", "accent-soft", "accent-line"]
def alpha_ok(v, pct):  # accent at pct%: a color-mix percentage, a rgba() alpha, or an 8-digit hex alpha
    v = v.strip()
    if re.search(r"(?<![\d.])%s(\.0+)?%%" % pct, v) and "color-mix" in v: return True
    m = re.fullmatch(r"rgba?\(.*[,/]\s*(0?\.\d+|\d+%)\s*\)", v)
    if m:
        a = m.group(1); a = float(a[:-1]) / 100 if a.endswith("%") else float(a)
        return abs(a - pct / 100) < .006
    m = re.fullmatch(r"#[0-9a-fA-F]{6}([0-9a-fA-F]{2})", v)
    return bool(m) and abs(int(m.group(1), 16) - round(pct * 2.55)) <= 1
for name, t in blocks.items():
    miss = [k for k in NEW if not t.get(k, "").strip()]
    if miss: bad.append(f"AC-1 {name}: does not define {miss}"); continue
    for k in ("raise", "accent-ink", "paper"):
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", t[k].strip()): bad.append(f"AC-1 {name}: {k} is not a hex color ({t[k].strip()})")
    if not alpha_ok(t["accent-soft"], 14): bad.append(f"AC-1 {name}: accent-soft is {t['accent-soft'].strip()}, want the accent at 14%")
    if not alpha_ok(t["accent-line"], 45): bad.append(f"AC-1 {name}: accent-line is {t['accent-line'].strip()}, want the accent at 45%")
    for bg in ("raise", "paper"):
        if re.fullmatch(r"#[0-9a-fA-F]{6}", t[bg].strip()) and re.fullmatch(r"#[0-9a-fA-F]{6}", t.get("text", "")):
            a, b = sorted((lum(t["text"]), lum(t[bg])), reverse=True)
            if (a + .05) / (b + .05) < 4.5: bad.append(f"AC-1 {name}: text on {bg} is {(a + .05) / (b + .05):.2f}:1")
# AC-1: Graphite and Paper take the Floor v4 table values exactly (the accent is --sand)
V4 = {
 "graphite": dict(ground="#141412", panel="#1b1b19", **{"panel-hi": "#23231f"}, raise_="#2a2925", edge="#2e2d29", **{"edge-hi": "#44423c"}, text="#ecebe6", soft="#cbc8bf", muted="#a29f95", faint="#8b887f", sand="#e9b44c", **{"accent-ink": "#1d1606"}, ok="#86c29c", warn="#e59a62", bad="#e8806f", track="#3b3a35", paper="#1f1e1b"),
 "paper": dict(ground="#f4f2ec", panel="#faf9f5", **{"panel-hi": "#ffffff"}, raise_="#ffffff", edge="#e2ddd2", **{"edge-hi": "#cdc6b8"}, text="#1f1d19", soft="#3e3a33", muted="#5f5a51", faint="#6f6a60", sand="#8f5b00", **{"accent-ink": "#ffffff"}, ok="#2f7a4b", warn="#a2531a", bad="#b4372a", track="#d9d3c6", paper="#fffdf8"),
}
for name, want in V4.items():
    if name not in blocks: bad.append(f'AC-1 {name}: no [data-theme="{name}"] block'); continue
    for k, v in want.items():
        k = "raise" if k == "raise_" else k
        got = blocks[name].get(k, "").strip().lower()
        if got != v: bad.append(f"AC-1 {name}: --{k} is {got or 'missing'}, Floor v4 says {v}")
    r = lambda x, y: (max(lum(x), lum(y)) + .05) / (min(lum(x), lum(y)) + .05)
    if all(re.fullmatch(r"#[0-9a-fA-F]{6}", blocks[name].get(k, "")) for k in ("accent-ink", "sand")) and r(blocks[name]["accent-ink"], blocks[name]["sand"]) < 4.5:
        bad.append(f"AC-1 {name}: accent-ink on the accent is {r(blocks[name]['accent-ink'], blocks[name]['sand']):.2f}:1")
# AC-1: today's blue "paper" is now Cobalt, with its old colors
cob = blocks.get("cobalt", {})
if cob.get("ground", "").strip().lower() != "#e3ebf6" or cob.get("sand", "").strip().lower() != "#006478": bad.append(f"AC-1 cobalt: ground/sand are {cob.get('ground')}/{cob.get('sand')}, want the old paper's #e3ebf6/#006478")
if "paper" in blocks and blocks["paper"].get("ground", "").strip().lower() == "#e3ebf6": bad.append("AC-1 paper is still the old blue theme")
print(len(blocks), "themes"); print("\n".join(bad) or "all readable")
PY
)"
assert_contains "$out" "14 themes"
assert_contains "$out" "all readable"

# Settings offers four themes first and the rest behind "More themes" (AC-5), and says which is in use when it is behind the fold (AC-6).
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0] + "/test"); import page_text  # the page's text is a catalog by key (#122)
h = page_text.english(h)
cat = json.load(open(sys.argv[2], encoding="utf-8"))
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
i = h.index("const THEMES"); win = h[i:i + 900]
pos = {k: win.find(k + ":") for k in ("first", "dark", "light")}
def ids(k):
    if pos[k] < 0: return []
    later = sorted(p for p in pos.values() if p > pos[k])
    return re.findall(r'"([a-z]+)"', win[pos[k]:later[0] if later else len(win)].split("\n")[0])
first, dark, light = ids("first"), ids("dark"), ids("light")
css = set(re.findall(r'\[data-theme="([a-z]+)"\]\s*\{', h))
check("AC-2 THEMES.first holds Auto, Graphite, Paper, High contrast in that order", first == ["auto", "graphite", "paper", "contrast"], f"first is {first}")
rest = dark + light
check("AC-2 dark and light keep the other eleven themes, none of the four", len(rest) == 11 and not set(rest) & set(first), f"dark+light are {rest}")
check("AC-2 Tape is dark; Kraft and Cobalt are light", "tape" in dark and "kraft" in light and "cobalt" in light, f"dark {dark}, light {light}")
check("AC-2 each of the fourteen themes is offered once", sorted(x for x in first + rest if x != "auto") == sorted(css) and len(css) == 14, f"offered {sorted(first + rest)}")
check("AC-2 Cobalt stays selectable", "cobalt" in rest and "cobalt" in css, "cobalt is not offered or has no css block")
fn = re.search(r"function theme\(pick\)\s*\{.*?\n\}", h, flags=re.S)
fb = fn.group(0) if fn else ""
auto = next((l for l in fb.splitlines() if "dataset.theme" in l), "")
check("AC-2 Auto resolves to Graphite in dark and Paper in light", "graphite" in auto and '"paper"' in auto and "prefers-color-scheme: light" in auto and "kraft" not in auto and "tape" not in auto, f"theme() sets the theme with: {auto.strip()}")
check("AC-2 pt-BR names Graphite, Paper and Cobalt", [page_text.msg("pt-BR", k) for k in ("theme.graphite", "theme.paper", "theme.cobalt")] == ["Graphite", "Paper", "Cobalt"], "theme.graphite/paper/cobalt are not Graphite/Paper/Cobalt in pt-BR")
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
check("AC-6 pt-BR In use: prefix", page_text.msg("pt-BR", "themes.in_use") == "Em uso: {theme}", "themes.in_use is not 'Em uso: {theme}'")
check("AC-5 pt-BR More themes", page_text.msg("pt-BR", "themes.more") == "Mais temas", "themes.more is not 'Mais temas'")
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
check("AC-5 fourteen themes are checked", len(blocks) == 14, f"{len(blocks)} themes")
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"

# The pool bar's four stage hues: --validate exists in every theme, is readable, and the four hues are told apart (AC-5, AC-6; #115).
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import itertools, math, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
blocks = {n: dict(re.findall(r"--([a-z0-9-]+):\s*([^;]+);", b)) for n, b in re.findall(r'\[data-theme="([a-z]+)"\]\s*\{([^}]*)\}', h)}
HEX = r"#[0-9a-fA-F]{6}"
res = []
def check(name, probs): res.append("ok " + name if not probs else "no " + name + ": " + "; ".join(probs))
def hexof(t, k):
    v = blocks[t].get(k, "").strip()
    return v if re.fullmatch(HEX, v) else None
def lin(c):
    v = [int(c[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return [x / 12.92 if x <= .04045 else ((x + .055) / 1.055) ** 2.4 for x in v]
def lum(c):
    r, g, b = lin(c); return .2126 * r + .7152 * g + .0722 * b
def lab(c):
    r, g, b = lin(c)
    x = (.4124564 * r + .3575761 * g + .1804375 * b) / .95047
    y = .2126729 * r + .7151522 * g + .0721750 * b
    z = (.0193339 * r + .1191920 * g + .9503041 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
def de(a, b): return math.dist(lab(a), lab(b))
def ratio(a, b):
    hi, lo = sorted((lum(a), lum(b)), reverse=True); return (hi + .05) / (lo + .05)

themes = sorted(blocks)
check("every one of the fourteen themes sets --validate as a hex color", [f"{t} has no --validate" for t in themes if not hexof(t, "validate")] + ([] if len(themes) == 14 else [f"{len(themes)} themes"]))
p = []
for t in themes:
    v = hexof(t, "validate")
    if not v: continue
    for bg in ("ground", "panel", "panel-hi"):
        r = ratio(v, hexof(t, bg))
        if r < 4.5: p.append(f"{t}: validate on {bg} is {r:.2f}:1")
check("validate is readable (4.5:1) on ground, panel and panel-hi in every theme", p + ([] if all(hexof(t, "validate") for t in themes) else ["--validate is not set in every theme"]))
p = []
for t in themes:
    for fg in ("refine", "text", "validate", "ok"):
        v = hexof(t, fg)
        if not v: p.append(f"{t}: {fg} is not a hex color"); continue
        r = ratio(v, hexof(t, "edge"))
        if r < 3: p.append(f"{t}: {fg} on edge is {r:.2f}:1")
check("refine, text, validate and ok hold 3:1 on edge in every theme", p)

m = re.search(r"const STAGE_HUE\s*=\s*\{([^}]*)\}", h)
hue = dict(re.findall(r'(\w+)\s*:\s*"([^"]*)"', m.group(1))) if m else {}
tok = {k: (re.fullmatch(r"var\(--([a-z0-9-]+)\)", v).group(1) if re.fullmatch(r"var\(--([a-z0-9-]+)\)", v) else None) for k, v in hue.items()}
p = []
if hue.get("validate") != "var(--validate)": p.append(f"STAGE_HUE.validate is {hue.get('validate')!r}, want 'var(--validate)'")
if not re.search(r"\.sbar[^\n]*STAGE_HUE\[st\]|sbar[\s\S]{0,200}STAGE_HUE\[st\]", h): p.append("the pool bar does not read STAGE_HUE[st]")
if not re.search(r'class="key"[\s\S]{0,200}STAGE_HUE\[st\]', h): p.append("the key does not read STAGE_HUE[st]")
kr, kv = hexof("kraft", tok.get("refine") or ""), hexof("kraft", tok.get("validate") or "")
if not kr or not kv: p.append(f"on Kraft the Refine ({tok.get('refine')}) and Validate ({tok.get('validate')}) hues do not both resolve to a hex color")
elif de(kr, kv) < 20: p.append(f"on Kraft Refine {kr} and Validate {kv} are only dE {de(kr, kv):.1f} apart, want 20")
check("AC-5 on Kraft the pool bar's Refine and Validate are told apart and the key reads the same map", p)

p = []
stages = ["refine", "develop", "validate", "deploy"]
for t in themes:
    cols = {}
    for st in stages:
        c = hexof(t, tok.get(st) or "")
        if c: cols[st] = c
        else: p.append(f"{t}: {st} ({tok.get(st)}) does not resolve to a color")
    sand = hexof(t, "sand")
    for st, c in cols.items():
        if sand and c.lower() == sand.lower(): p.append(f"{t}: {st} is the accent (sand {sand})")
    for a, b in itertools.combinations(cols, 2):
        d = de(cols[a], cols[b])
        if d < 20: p.append(f"{t}: {a} {cols[a]} and {b} {cols[b]} are dE {d:.1f} apart")
check("AC-6 in all fourteen themes the four pool-bar stage colors are four different colors, none the accent", p)
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
