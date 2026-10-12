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
check("every one of the twelve themes sets --validate as a hex color", [f"{t} has no --validate" for t in themes if not hexof(t, "validate")] + ([] if len(themes) == 12 else [f"{len(themes)} themes"]))
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
check("AC-6 in all twelve themes the four pool-bar stage colors are four different colors, none the accent", p)
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
