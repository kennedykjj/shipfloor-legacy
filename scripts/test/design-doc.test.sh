#!/usr/bin/env bash
# DESIGN.md and its sidecar describe the shipped dashboard (scripts/dashboard.html), not the page before the rename.
# Reads three files of the repository: scripts/dashboard.html, DESIGN.md, .impeccable/design.json.
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$FACTORY_DIR/.." && pwd)"
out="$("$FACTORY_PYTHON" - "$ROOT" <<'PY'
import json, os, re, sys
import yaml

root = sys.argv[1]
rd = lambda p: open(os.path.join(root, p), encoding="utf-8", newline=None).read()
html = rd("scripts/dashboard.html")
design = rd("DESIGN.md").replace("\r\n", "\n")
sidecar_text = rd(".impeccable/design.json")
sidecar = json.loads(sidecar_text)

res = []
def ok(name): res.append(f"PASS {name}")
def bad(name, msg): res.append(f"FAIL {name}: {msg}")
def check(name, cond, msg):
    ok(name) if cond else bad(name, msg)

# ---- the page
css = html[html.index("<style>") + 7:html.index("</style>")]
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
css = re.sub(r"@font-face\s*\{[^}]*\}", "", css)
rules = [(re.sub(r"\s+", " ", s).strip(), b) for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", css)]

def var(name):
    m = re.search(r"--%s:\s*([^;]+);" % name, css)
    return m.group(1).strip() if m else ""

def norm(v):
    v = v.strip().lower().replace("!important", "").strip()
    m = re.fullmatch(r"(\d*\.?\d+)(px|rem|em|%)", v)
    if not m or float(m.group(1)) == 0 or v == "50%":
        return None
    return f"{float(m.group(1)):g}{m.group(2)}"

uses = {"font-size": {}, "border-radius": {}}   # property -> value -> [selectors]
def use(prop, raw, sel):
    v = norm(raw)
    if v: uses[prop].setdefault(v, [])
    if v and sel not in uses[prop][v]: uses[prop][v].append(sel)
for sel, body in rules:
    if sel.startswith("@"): continue
    for raw in re.findall(r"(?<![\w-])font-size\s*:\s*([^;}]+)", body): use("font-size", raw, sel)
    for raw in re.findall(r"(?<![\w-])font\s*:\s*([^;}]+)", body):
        for tok in raw.split():
            m = re.match(r"^(\d*\.?\d+(?:px|rem|em))(?:/.*)?$", tok)
            if m: use("font-size", m.group(1), sel); break
    for raw in re.findall(r"(?<![\w-])border-radius\s*:\s*([^;}]+)", body):
        for tok in re.split(r"[\s/]+", raw.strip()): use("border-radius", tok, sel)

base = re.search(r':root,\s*\[data-theme="charcoal"\]\s*\{([^}]*)\}', css).group(1)
tokens = {k: v.lower() for k, v in re.findall(r"--([a-z0-9-]+):\s*(#[0-9a-fA-F]{6})\s*;", base)}
theme_ids = sorted(set(re.findall(r'\[data-theme="([a-z]+)"\]\s*\{', css)))

# ---- DESIGN.md
m = re.match(r"---\n(.*?)\n---\n", design, flags=re.S)
try:
    front = yaml.safe_load(m.group(1)) if m else {}
    check("front matter is valid YAML", bool(m), "DESIGN.md has no front matter")
except yaml.YAMLError as e:
    front = {}
    bad("front matter is valid YAML", "DESIGN.md front matter does not parse: " + str(e).splitlines()[0] + " " + str(getattr(e, "problem_mark", "")))
body = design[m.end():] if m else design
front = front if isinstance(front, dict) else {}
colors = front.get("colors") or {}
typo = front.get("typography") or {}
rounded = front.get("rounded") or {}

# AC-1: fonts
fams = " | ".join(str(t.get("fontFamily", "")) for t in typo.values() if isinstance(t, dict))
check("AC-1 typography declares Barlow", "Barlow" in fams.replace("Barlow Condensed", ""),
      "no typography fontFamily names Barlow (the page's --sans: %s)" % var("sans"))
check("AC-1 typography declares Barlow Condensed", "Barlow Condensed" in fams,
      "no typography fontFamily names Barlow Condensed (the page's --cond: %s)" % var("cond"))
check("AC-1 typography declares the mono stack", "ui-monospace" in fams and "Cascadia Mono" in fams,
      "no typography fontFamily is the page's --mono stack (%s)" % var("mono"))
check("AC-1 says both Barlow faces are embedded in the file",
      re.search(r"embedded[^\n]*Barlow|Barlow[^\n]*embedded", design, flags=re.I) is not None,
      "DESIGN.md never says the Barlow faces are embedded in the file")
check("AC-1 no longer says no webfonts", re.search(r"no\s+web\s?fonts?", design, flags=re.I) is None,
      "DESIGN.md still says \"no webfonts\"")

# AC-2: every font-size and border-radius is in the ramp/scale or under Known deviations
ramp = {n for n in (norm(str(t.get("fontSize", ""))) for t in typo.values() if isinstance(t, dict)) if n}
scale = {n for n in (norm(str(v)) for v in rounded.values()) if n}
dev = re.search(r"^## Known deviations[ \t]*\n(.*?)(?=^## |\Z)", design, flags=re.S | re.M)
listed = {}
if dev:
    for v, s in re.findall(r"`([^`]+)`\s*[—–-]+\s*`([^`]+)`", dev.group(1)):
        n = norm(v)
        if n: listed.setdefault(n, []).append(re.sub(r"\s+", " ", s).strip())
def declared(prop, v, sels):
    if v in (ramp if prop == "font-size" else scale): return True
    for ls in listed.get(v, []):
        for s in sels:
            if ls == s or ls in s or s in ls: return True
    return False
if not dev:
    bad("AC-2 Known deviations heading", "DESIGN.md has no \"## Known deviations\" heading")
for prop, label in (("font-size", "type ramp"), ("border-radius", "radius scale")):
    miss = [(v, s) for v, s in sorted(uses[prop].items()) if not declared(prop, v, s)]
    for v, s in miss:
        bad(f"AC-2 {prop} {v}", f"{v} (used by {', '.join(s[:3])}) is not in the {label} and not listed under Known deviations with its selector")
    if not miss: ok(f"AC-2 every {prop} value is in the {label} or listed under Known deviations")

# AC-3: colors front matter == base :root tokens
for k, v in sorted(tokens.items()):
    got = str(colors.get(k, "")).lower()
    check(f"AC-3 colors.{k}", got == v, f"colors.{k} is {got or 'missing'}, the page's --{k} is {v}")
extra = sorted(set(colors) - set(tokens))
check("AC-3 no color is declared that the page lacks", not extra, f"colors declares {extra} but the page's base block has no such token")
check("AC-3 gold and azure are not color keys", "gold" not in colors and "azure" not in colors,
      "colors still declares gold/azure; the page only aliases them to sand and text")

# AC-4: retired terms
retired = ["item shop", "Item Tooltip", "parchment", "stone-", "Deep Slate", "never uppercase", "ten columns",
           "#e2b356", "#63b2ff", "#ebe5d5", "#0d1014"]
for term in retired:
    where = [n for n, t in (("DESIGN.md", design), (".impeccable/design.json", sidecar_text)) if term in t]
    check(f"AC-4 retired term \"{term}\" is gone", not where, f"\"{term}\" is still in {', '.join(where)}")

# AC-5: the shipped page
check("AC-5 describes the lifecycle band", re.search(r"lifecycle\s+band", design, flags=re.I) is not None,
      "DESIGN.md never mentions the lifecycle band")
for v in ("Factory", "Feed", "Settings"):
    check(f"AC-5 names the {v} view", re.search(r"\b%s\b" % v, design) is not None, f"DESIGN.md never names the {v} view")
check("AC-5 describes the uppercase captions",
      any(re.search(r"caption", l, flags=re.I) and re.search(r"uppercase", l, flags=re.I) and "never uppercase" not in l
          for l in design.splitlines()),
      "no line of DESIGN.md says the captions are uppercase")
sec = re.search(r"^(#+)[ \t]*Themes[ \t]*\n(.*?)(?=^#{1,%d}[ \t]|\Z)", design, flags=re.S | re.M)
tsec = ""
if sec:
    lvl = len(sec.group(1))
    tsec = re.search(r"^#+[ \t]*Themes[ \t]*\n(.*?)(?=^#{1,%d}[ \t]|\Z)" % lvl, design, flags=re.S | re.M).group(1)
check("AC-5 has a Themes section", bool(sec), "DESIGN.md has no Themes heading")
check("AC-5 themes section lists the page's %d theme ids" % len(theme_ids),
      all(re.search(r"\b%s\b" % t, tsec, flags=re.I) for t in theme_ids),
      "Themes section misses " + str([t for t in theme_ids if not re.search(r"\b%s\b" % t, tsec, flags=re.I)]))

# AC-6: sidecar against the front matter
cm = (sidecar.get("extensions") or {}).get("colorMeta") or {}
tm = (sidecar.get("extensions") or {}).get("typographyMeta") or {}
check("AC-6 sidecar names colors and typography", bool(cm) and bool(tm), "the sidecar names no colorMeta or typographyMeta entry")
badc = []
for k, e in cm.items():
    want = str((e or {}).get("canonical", "")).lower()
    if str(colors.get(k, "")).lower() != want: badc.append(f"{k} ({want} vs {colors.get(k, 'missing')})")
check("AC-6 every sidecar color is in the front matter with the same value", not badc, "differ: " + ", ".join(badc))
badt = [k for k in tm if k not in typo]
check("AC-6 every sidecar typography entry is in the front matter", not badt, "not in typography: " + ", ".join(badt))
gen = str(sidecar.get("generatedAt", ""))[:10]
check("AC-6 generatedAt is on or after 2026-10-11", gen >= "2026-10-11", f"generatedAt is {gen or 'missing'}")

# ---- #120: the twelve values the detector reported
# AC-2: the six font sizes are gone from the page; 28px is a step of the ramp
for px in ("16px", "21px", "22px", "24px", "26px", "30px"):
    sels = uses["font-size"].get(px, [])
    check(f"AC-2 no rule uses font-size {px}", not sels, f"{px} is still used by {', '.join(sels[:4])}")
check("AC-2 28px is a step of the type ramp (typography.section)", "28px" in ramp,
      f"the ramp is {sorted(ramp)}; typography.section is {typo.get('section', 'missing')}")
check("AC-2 typography.section is 28px", norm(str((typo.get("section") or {}).get("fontSize", ""))) == "28px",
      f"typography.section.fontSize is {(typo.get('section') or {}).get('fontSize', 'missing')}")

# AC-3: the radii 1, 10, 14px are gone from the page; 40px is the named step rounded.pill
for px in ("1px", "10px", "14px"):
    sels = uses["border-radius"].get(px, [])
    check(f"AC-3 no rule uses border-radius {px}", not sels, f"{px} is still used by {', '.join(sels[:4])}")
check("AC-3 rounded.pill is 40px", str(rounded.get("pill", "")).strip() == "40px", f"rounded.pill is {rounded.get('pill', 'missing')}")
check("AC-3 40px is a step of the radius scale", "40px" in scale, f"the scale is {sorted(scale)}")
check("AC-3 Shapes names the pill step", re.search(r"^#+[ \t]*Shapes[ \t]*\n(?:(?!^#{1,3}[ \t]).)*\bpill\b", design, flags=re.S | re.M | re.I) is not None,
      "the Shapes section never names the pill")

# AC-4: the decision column's well and the pill's hover come from tokens
lit = re.compile(r"#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(|\b(?:white|black|gray|grey|red|green|blue|silver|yellow|orange|purple|navy|teal|maroon|olive|lime|aqua|fuchsia)\b", re.I)
idec = [b for s, b in rules if s == ".idec"]
check("AC-4 the .idec rule exists", len(idec) == 1, f"found {len(idec)} rules for .idec")
body_idec = idec[0] if idec else ""
check("AC-4 .idec holds no color literal", not lit.search(body_idec), "the .idec rule has a literal color: " + ", ".join(m.group(0) for m in lit.finditer(body_idec)))
check("AC-4 .idec background is var(--well)", re.search(r"(?<![\w-])background\s*:\s*var\(--well\)\s*[;}]?", body_idec) is not None,
      "the .idec background is " + (re.search(r"(?<![\w-])background\s*:\s*([^;]+)", body_idec).group(1).strip() if re.search(r"(?<![\w-])background\s*:", body_idec) else "missing"))
hov = [b for s, b in rules if ".pill:hover" in s]
check("AC-4 the Approve pill has a hover rule", len(hov) >= 1, "no rule for .pill:hover")
for i, b in enumerate(hov):
    check("AC-4 the .pill:hover rule holds no color literal", not lit.search(b), "the .pill:hover rule has a literal color: " + ", ".join(m.group(0) for m in lit.finditer(b)))
    bg = re.search(r"(?<![\w-])background\s*:\s*([^;]+)", b)
    bgv = bg.group(1).strip() if bg else ""
    check("AC-4 the .pill:hover background is a color-mix over tokens",
          bool(re.fullmatch(r"color-mix\(\s*in srgb\s*,\s*var\(--[a-z-]+\)[^,]*,\s*var\(--[a-z-]+\)[^,]*\)", bgv)),
          f"the .pill:hover background is {bgv or 'missing'}")

# AC-6: Known deviations lists only values the page still uses, and none this issue resolved
devtxt = dev.group(1) if dev else ""
items = re.findall(r"`([^`]+)`\s*[—–-]+\s*`([^`]+)`", devtxt)
check("AC-6 Known deviations lists no value this issue resolved",
      not [v for v, _ in items if norm(v) in {"16px", "21px", "22px", "24px", "26px", "30px", "1px", "10px", "14px", "40px"}],
      "still listed: " + ", ".join(v for v, _ in items if norm(v) in {"16px", "21px", "22px", "24px", "26px", "30px", "1px", "10px", "14px", "40px"}))
for v, s in items:
    n = norm(v)
    sels = [x for p in uses for x in uses[p].get(n, [])] if n else []
    sel = re.sub(r"\s+", " ", s).strip()
    check(f"AC-6 Known deviations `{v}` is used by {sel} on the page", any(sel == x or sel in x or x in sel for x in sels),
          f"{v} is listed for {sel} but the page uses it in: {', '.join(sels) or 'no rule'}")
check("AC-6 Known deviations keeps 15.5px (.isec .plain)", any(norm(v) == "15.5px" for v, _ in items), "the 15.5px line is gone")

print("\n".join(res))
PY
)"
if [ -z "$out" ]; then fail "the check printed nothing"; fi
while IFS= read -r line; do
  case "$line" in
    PASS\ *) pass "${line#PASS }" ;;
    FAIL\ *) fail "${line#FAIL }" ;;
  esac
done <<< "$out"
finish
