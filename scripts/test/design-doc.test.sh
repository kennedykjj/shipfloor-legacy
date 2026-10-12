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

# AC-8 (#117): the caption is 12px / 0.1em, no 11px or 11.5px role is left, the 24x24px target, the switch's word
cap = typo.get("caption") if isinstance(typo.get("caption"), dict) else {}
check("AC-8 front matter Caption is 12px with 0.1em tracking",
      norm(str(cap.get("fontSize", ""))) == "12px" and str(cap.get("letterSpacing", "")).replace("0.1em", ".1em") == ".1em",
      "typography.caption is %s / %s, want 12px / 0.1em" % (cap.get("fontSize", "missing"), cap.get("letterSpacing", "missing")))
cline = next((l for l in design.splitlines() if re.match(r"\s*-\s*\*\*Caption\*\*", l)), "")
check("AC-8 Hierarchy gives Caption as 12px and 0.1em",
      "12px" in cline and "0.1em" in cline and "11px" not in cline and "0.14em" not in cline,
      "the Caption line of Hierarchy is: " + (cline or "missing"))
small = sorted({k for k, t in typo.items() if isinstance(t, dict) and norm(str(t.get("fontSize", ""))) in ("11px", "11.5px")})
check("AC-8 the type ramp has no 11px or 11.5px role", not small and "note" not in typo,
      "typography still has " + ", ".join(small or ["note"]))
check("AC-8 DESIGN.md names no 11px or 11.5px size", re.search(r"(?<![\d.])11(\.5)?px", design) is None,
      "DESIGN.md still mentions " + ", ".join(sorted(set(re.findall(r"(?<![\d.])11(?:\.5)?px", design)))))
check("AC-8 Meta is named Meta (12px), with no separate note role", "Meta (12px)" in design and re.search(r"Meta\*\* and \*\*note", design) is None,
      "Hierarchy does not read \"Meta (12px)\" or still has \"Meta and note\"")
btn = re.search(r"^#+[ \t]*Buttons[ \t]*\n(.*?)(?=^#{1,3}[ \t]|\Z)", design, flags=re.S | re.M)
check("AC-8 Buttons names the 24x24px minimum target", bool(btn) and re.search(r"24\s*x\s*24\s*px", btn.group(1)) is not None
      and re.search(r"Target", btn.group(1)) is not None,
      "the Buttons section has no \"Target\" rule of at least 24x24px")
check("AC-8 says a Settings switch shows its state as a word",
      any("switch" in l.lower() and re.search(r"\bwords?\b", l) and re.search(r"\bstate\b", l) for l in design.splitlines()),
      "no line of DESIGN.md says a switch shows its state as a word")
check("AC-8 Today says the chart labels are 12px", re.search(r"Chart labels are 12px", design) is not None,
      "Today does not read \"Chart labels are 12px\"")
dscap = next((c.get("css", "") for c in (sidecar.get("components") or []) if isinstance(c, dict) and ".ds-cap{" in str(c.get("css", ""))), "")
if not dscap:
    m2 = re.search(r"\.ds-cap\{[^}]*\}", sidecar_text)
    dscap = m2.group(0) if m2 else ""
check("AC-8 the sidecar agrees on the caption size",
      bool(dscap) and "12px" in dscap and ".1em" in dscap and "11px" not in dscap and ".14em" not in dscap,
      "the sidecar's .ds-cap is: " + (dscap[:120] or "missing"))
check("AC-8 the sidecar has no 11px or 11.5px size", re.search(r"(?<![\d.])11(\.5)?px", sidecar_text) is None,
      "the sidecar still mentions 11px or 11.5px")

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
