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
check("AC-7 typography declares IBM Plex Sans", "IBM Plex Sans" in fams,
      "no typography fontFamily names IBM Plex Sans (the page's --sans: %s)" % var("sans"))
check("AC-7 typography declares IBM Plex Mono", "IBM Plex Mono" in fams and "ui-monospace" in fams,
      "no typography fontFamily is IBM Plex Mono with the ui-monospace fallback (the page's --mono: %s)" % var("mono"))
check("AC-7 no Barlow is left in DESIGN.md or the sidecar", "Barlow" not in design and "Barlow" not in sidecar_text,
      "Barlow is still named in " + ", ".join(n for n, t in (("DESIGN.md", design), (".impeccable/design.json", sidecar_text)) if "Barlow" in t))
check("AC-7 says the Plex faces are embedded in the file",
      re.search(r"embedded[^\n]*Plex|Plex[^\n]*embedded", design, flags=re.I) is not None,
      "DESIGN.md never says the IBM Plex faces are embedded in the file")
tsec_ty = re.search(r"^#+[ \t]*Typography[ \t]*\n(.*?)(?=^## |\Z)", design, flags=re.S | re.M)
tytxt = tsec_ty.group(1) if tsec_ty else ""
check("AC-7 Typography says nothing is under 12px", re.search(r"nothing\s+(?:is\s+)?(?:set\s+)?under\s+12px", tytxt, flags=re.I) is not None,
      "the Typography section never says nothing is under 12px")
check("AC-7 Typography caps running text at 64ch", "64ch" in tytxt, "the Typography section never names the 64ch measure")
rsz = sorted({float(n[:-2]) for n in (norm(str(t.get("fontSize", ""))) for t in typo.values() if isinstance(t, dict)) if n and n.endswith("px")})
check("AC-7 the type scale runs from 34px down to 12px", bool(rsz) and rsz[-1] == 34 and rsz[0] == 12 and set(rsz) <= {34, 24, 17, 16, 15, 14, 13, 12},
      f"the front matter sizes are {rsz}, want only 34, 24, 17, 16, 15, 14, 13, 12 with both 34 and 12 present")
check("AC-7 the sidecar's typography agrees: no size under 12px", not [p for p in re.findall(r"font-size\s*:\s*(\d*\.?\d+)px", sidecar_text) if float(p) < 12],
      "the sidecar has a font-size under 12px")
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
retired = ["item shop", "Item Tooltip", "parchment", "stone-", "Deep Slate", "ten columns",
           "#e2b356", "#63b2ff", "#ebe5d5", "#0d1014"]
for term in retired:
    where = [n for n, t in (("DESIGN.md", design), (".impeccable/design.json", sidecar_text)) if term in t]
    check(f"AC-4 retired term \"{term}\" is gone", not where, f"\"{term}\" is still in {', '.join(where)}")

# AC-5: the shipped page
check("AC-5 describes the lifecycle band", re.search(r"lifecycle\s+band", design, flags=re.I) is not None,
      "DESIGN.md never mentions the lifecycle band")
for v in ("Factory", "Feed", "Settings"):
    check(f"AC-5 names the {v} view", re.search(r"\b%s\b" % v, design) is not None, f"DESIGN.md never names the {v} view")
neg = re.compile(r"\b(?:no|never|not|don't|without|exceptions?|nothing)\b", re.I)
check("AC-7 no line of DESIGN.md asks for uppercase except to forbid it or list an exception",
      not [l for l in design.splitlines() if re.search(r"uppercase", l, flags=re.I) and not neg.search(l)],
      "still says uppercase: " + "; ".join(l.strip()[:70] for l in design.splitlines() if re.search(r"uppercase", l, flags=re.I) and not neg.search(l))[:300])
check("AC-7 no line of DESIGN.md keeps captions or headings uppercase or condensed",
      not [l for l in design.splitlines() if re.search(r"condensed|tracked\s+(?:wide|captions)|uppercase\s+(?:and\s+)?tracked|uppercase captions", l, flags=re.I) and not neg.search(l)],
      "a line still describes condensed or tracked uppercase type")
sec = re.search(r"^(#+)[ \t]*Themes[ \t]*\n(.*?)(?=^#{1,%d}[ \t]|\Z)", design, flags=re.S | re.M)
tsec = ""
if sec:
    lvl = len(sec.group(1))
    tsec = re.search(r"^#+[ \t]*Themes[ \t]*\n(.*?)(?=^#{1,%d}[ \t]|\Z)" % lvl, design, flags=re.S | re.M).group(1)
check("AC-5 has a Themes section", bool(sec), "DESIGN.md has no Themes heading")
check("AC-5 themes section lists the page's %d theme ids" % len(theme_ids),
      all(re.search(r"\b%s\b" % t, tsec, flags=re.I) for t in theme_ids),
      "Themes section misses " + str([t for t in theme_ids if not re.search(r"\b%s\b" % t, tsec, flags=re.I)]))

# AC-7 (#180): Colors, Themes, Do's and Don'ts and the front matter say the v4 system
csec = re.search(r"^## Colors[ \t]*\n(.*?)(?=^## |\Z)", design, flags=re.S | re.M)
ctxt = csec.group(1) if csec else ""
sents = re.split(r"(?<=[.!?])\s+|\n", ctxt)
check("AC-7 Colors says the accent marks only what waits for the owner",
      any(re.search(r"accent|`sand`", s) and re.search(r"\bonly\b", s) and re.search(r"wait", s) and re.search(r"\bowner\b", s) for s in sents),
      "no sentence of Colors says the accent marks only what waits for the owner")
check("AC-7 Colors puts costs in `text` with `est`",
      any(re.search(r"\bcosts?\b", s) and "`text`" in s and re.search(r"`est`|\best\b", s) for s in sents),
      "no sentence of Colors says costs are in `text` with `est`")
check("AC-7 Colors does not use the accent for money", not any(re.search(r"\b(?:money|cost)", s, flags=re.I) and re.search(r"accent|`sand`", s) and not neg.search(s) and "`text`" not in s for s in sents),
      "Colors still ties the accent to money or costs")
check("AC-7 Themes names Graphite, Paper and Cobalt", all(re.search(r"\b%s\b" % n, tsec) for n in ("Graphite", "Paper", "Cobalt")),
      "the Themes section misses " + str([n for n in ("Graphite", "Paper", "Cobalt") if not re.search(r"\b%s\b" % n, tsec)]))
check("AC-7 Themes says Auto is Graphite in dark and Paper in light",
      re.search(r"Auto[^\n]*Graphite[^\n]*dark[^\n]*Paper[^\n]*light|Auto[^\n]*dark[^\n]*Graphite[^\n]*light[^\n]*Paper", tsec) is not None and "Kraft in light" not in tsec,
      "the Themes section does not say Auto follows the system with Graphite in dark and Paper in light")
check("AC-7 Themes lists the five new tokens", all(f"`{k}`" in tsec for k in ("raise", "accent-ink", "paper", "accent-soft", "accent-line")),
      "the Themes token list misses " + str([k for k in ("raise", "accent-ink", "paper", "accent-soft", "accent-line") if f"`{k}`" not in tsec]))
dd = re.search(r"^## Do's and Don'ts[ \t]*\n(.*?)(?=^## |\Z)", design, flags=re.S | re.M)
ddt = dd.group(1) if dd else ""
check("AC-7 Do's and Don'ts forbid uppercase", any(re.search(r"uppercase", l, flags=re.I) and re.search(r"\*\*Don't\*\*|\b(?:no|never|not)\b", l) for l in ddt.splitlines()),
      "no Don't line forbids uppercase")
check("AC-7 Do's and Don'ts keep the accent for what waits for the owner", any(re.search(r"accent", l) and re.search(r"wait", l) and re.search(r"\bowner\b", l) for l in ddt.splitlines()),
      "no Do or Don't line ties the accent to what waits for the owner")
check("AC-7 Do's and Don'ts no longer keep captions uppercase", not re.search(r"keep captions uppercase|headings condensed", ddt), "the Do's still keep captions uppercase")
check("AC-7 front matter carries the new tokens", all(k in colors for k in ("raise", "accent-ink", "paper")),
      "colors misses " + str([k for k in ("raise", "accent-ink", "paper") if k not in colors]))
check("AC-7 front matter radius: panel 16px, decision panel 14px, tokens 8px, pill 999px",
      [str(rounded.get(k, "")).strip() for k in ("pill",)] == ["999px"] and {"16px", "14px", "8px"} <= scale,
      f"rounded is {rounded}")

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
check("AC-6 generatedAt is on or after 2026-10-14", gen >= "2026-10-14", f"generatedAt is {gen or 'missing'}")

# ---- #120: the twelve values the detector reported
# AC-2: the six font sizes are gone from the page; 28px is a step of the ramp
for px in ("21px", "22px", "26px", "28px", "30px"):  # 16px and 24px are v4 roles (brief prose, card title); 28px leaves with the condensed headings
    sels = uses["font-size"].get(px, [])
    check(f"AC-2 no rule uses font-size {px}", not sels, f"{px} is still used by {', '.join(sels[:4])}")
check("AC-2 28px is not a step of the type ramp any more", "28px" not in ramp, f"the ramp is {sorted(ramp)}")

# AC-3: the radii 1, 10px are gone from the page; the pill is fully rounded (999px, v4)
for px in ("1px", "10px"):
    sels = uses["border-radius"].get(px, [])
    check(f"AC-3 no rule uses border-radius {px}", not sels, f"{px} is still used by {', '.join(sels[:4])}")
check("AC-3 rounded.pill is 999px", str(rounded.get("pill", "")).strip() == "999px", f"rounded.pill is {rounded.get('pill', 'missing')}")
check("AC-3 40px is no longer a step of the radius scale", "40px" not in scale, f"the scale is {sorted(scale)}")
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
      not [v for v, _ in items if norm(v) in {"21px", "22px", "26px", "28px", "30px", "1px", "10px", "40px"}],
      "still listed: " + ", ".join(v for v, _ in items if norm(v) in {"21px", "22px", "26px", "28px", "30px", "1px", "10px", "40px"}))
for v, s in items:
    n = norm(v)
    sels = [x for p in uses for x in uses[p].get(n, [])] if n else []
    sel = re.sub(r"\s+", " ", s).strip()
    check(f"AC-6 Known deviations `{v}` is used by {sel} on the page", any(sel == x or sel in x or x in sel for x in sels),
          f"{v} is listed for {sel} but the page uses it in: {', '.join(sels) or 'no rule'}")
check("AC-6 Known deviations keeps 15.5px (.isec .plain)", any(norm(v) == "15.5px" for v, _ in items), "the 15.5px line is gone")

# AC-7: the waiting tile and the pool bar are described as the page draws them (#115)
def section(title, level):
    s = re.search(r"^#{%d}[ \t]*%s[ \t]*\n(.*?)(?=^#{1,%d}[ \t]|\Z)" % (level, re.escape(title), level), design, flags=re.S | re.M)
    return s.group(1) if s else ""
prog = section("In Progress", 3)
sett = section("Settings", 3)
check("AC-7 DESIGN.md no longer says a tile \"says why in the accent\"", "says why in the accent" not in design,
      "DESIGN.md still says \"says why in the accent\"")
miss = [w for w, ok_ in (("a section \"In Progress\"", bool(prog)),
                         ("hollow", re.search(r"hollow", prog, flags=re.I) is not None),
                         ("`muted`", "`muted`" in prog), ("`soft`", "`soft`" in prog), ("`warn`", "`warn`" in prog),
                         ("infrastructure", re.search(r"infrastructure", prog, flags=re.I) is not None),
                         ("the accent only on a tile that waits for the owner", re.search(r"accent[^.]*\bowner\b|\bowner\b[^.]*accent", prog) is not None),
                         ("the cost in `text` with `est`", re.search(r"cost[^.]*`text`|`text`[^.]*cost", prog) is not None and re.search(r"`est`|\best\b", prog) is not None)) if not ok_]
check("AC-7 the In Progress paragraph describes the waiting tile's ring and reason (muted, soft, warn, accent only for the owner, cost in text with est)", not miss,
      "the In Progress section does not mention " + ", ".join(miss))
pb = re.search(r"[^.\n]*pool bar[^\n]*", sett)
check("AC-7 the Settings pool bar sentence names validate", bool(pb) and "`validate`" in pb.group(0),
      "the Settings pool bar sentence does not name `validate`" if pb else "the Settings section has no pool bar sentence")
check("AC-7 the Settings pool bar sentence names the hue of every stage (refine, text, validate, ok)",
      bool(pb) and all(t in pb.group(0) for t in ("`refine`", "`text`", "`validate`", "`ok`")),
      "the Settings pool bar sentence misses one of `refine`, `text`, `validate`, `ok`")
check("AC-7 the Themes token list ends with refine, validate", re.search(r"`refine`,\s*`validate`", tsec) is not None,
      "the Themes section's token list does not end with `refine`, `validate`")

# AC-8 (#117): the caption is 12px / 0.1em, no 11px or 11.5px role is left, the 24x24px target, the switch's word
cap = typo.get("caption") if isinstance(typo.get("caption"), dict) else {}
check("AC-8 front matter Caption is 12px, 400, with no tracking",
      norm(str(cap.get("fontSize", ""))) == "12px" and str(cap.get("fontWeight", "")) == "400" and str(cap.get("letterSpacing", "0")).strip() in ("", "0", "0em", "0px", "normal", "None"),
      "typography.caption is %s / %s / %s, want 12px / 400 / no tracking" % (cap.get("fontSize", "missing"), cap.get("fontWeight", "missing"), cap.get("letterSpacing", "none")))
cline = next((l for l in design.splitlines() if re.match(r"\s*-\s*\*\*Caption\*\*", l)), "")
check("AC-8 Hierarchy gives Caption as 12px, 400, sentence case",
      "12px" in cline and "400" in cline and "0.1em" not in cline and "0.14em" not in cline and "11px" not in cline,
      "the Caption line of Hierarchy is: " + (cline or "missing"))
small = sorted({k for k, t in typo.items() if isinstance(t, dict) and norm(str(t.get("fontSize", ""))) in ("11px", "11.5px")})
check("AC-8 the type ramp has no 11px or 11.5px role", not small and "note" not in typo,
      "typography still has " + ", ".join(small or ["note"]))
check("AC-8 DESIGN.md names no 11px or 11.5px size", re.search(r"(?<![\d.])11(\.5)?px", design) is None,
      "DESIGN.md still mentions " + ", ".join(sorted(set(re.findall(r"(?<![\d.])11(?:\.5)?px", design)))))
check("AC-8 Meta is named Meta (13px), with no separate note role", "Meta (13px)" in design and re.search(r"Meta\*\* and \*\*note", design) is None,
      "Hierarchy does not read \"Meta (13px)\" or still has \"Meta and note\"")
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
check("AC-8 the sidecar agrees on the caption: 12px, not uppercase, not tracked",
      (not dscap) or ("12px" in dscap and ".1em" not in dscap and ".14em" not in dscap and "uppercase" not in dscap and "11px" not in dscap),
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
