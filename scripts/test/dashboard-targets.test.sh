#!/usr/bin/env bash
# Dashboard targets and type (#117): every control has a box of at least 24x24px, a Settings switch says its state
# (role, aria-checked, the word On/Off), and no text on the page is under 12px.
# Read as text, as dashboard-page.test.sh and theme.test.sh do: no browser, no server. The pixel measures
# (AC-3 overlap, AC-5 grayscale, AC-7 one-row summary at 1280x800) are manual, taken in validation on the demo stack.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8", newline=None).read()
cat = json.load(open(sys.argv[2], encoding="utf-8"))
exact = cat.get("exact", {})

res = []
def check(name, problems):
    bad = [p for p in problems if p]
    res.append((name, bad))

css = h[h.index("<style>") + 7:h.index("</style>")]
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
css = re.sub(r"@font-face\s*\{[^}]*\}", "", css)
rules = []  # ([selector, ...], body)
for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
    sels = [re.sub(r"\s+", " ", x).strip() for x in s.split(",")]
    rules.append((sels, b))

def bodies(*patterns):  # the bodies of the rules with a selector that matches one of the regexes (whole selector)
    out = []
    for sels, b in rules:
        if any(re.fullmatch(p, x) for p in patterns for x in sels): out.append(b)
    return out

def last(body, prop):  # the last value of `prop` in the bodies, or None
    vals = re.findall(r"(?<![\w-])" + re.escape(prop) + r"\s*:\s*([^;}]+)", body)
    return vals[-1].strip() if vals else None

def px(v):
    m = re.fullmatch(r"([\d.]+)px", (v or "").strip().lower())
    return float(m.group(1)) if m else None

def declared_min(bs, prop):  # the largest px value of `prop` over the bodies
    vals = [px(last(b, prop)) for b in bs]
    vals = [v for v in vals if v is not None]
    return max(vals) if vals else None

def target(label, pats, full):
    bs = bodies(*pats)
    if not bs: return f"{label}: no CSS rule for it (looked for {' | '.join(pats)})"
    mh = max(filter(None, (declared_min(bs, "min-height"), declared_min(bs, "height"))), default=None)  # a fixed box counts too
    if mh is None or mh < 24: return f"{label}: min-height is {mh}, not at least 24px"
    if full:
        mw = max(filter(None, (declared_min(bs, "min-width"), declared_min(bs, "width"))), default=None)
        if mw is None or mw < 24: return f"{label}: min-width is {mw}, not at least 24px"
        disp = " ".join(last(b, "display") or "" for b in bs)
        if "inline-flex" not in disp: return f"{label}: display is not inline-flex"
    return None

# Controls of the Factory view (AC-1) and of the Feed, Settings and the drawer (AC-2): the selectors the spec names.
factory = [
    ("the view buttons (.views button)", [r"\.views button"], False),
    ("the Maximize buttons and the Lifecycle and Today folds (.max)", [r"\.max"], False),
    ("the project select (.proj select)", [r"\.proj select"], False),
    ("Board on GitHub (a.cap in .stats)", [r"(\.stats )?a\.cap", r"\.stats a"], True),
    ("the Log link in .tfoot (.lnk)", [r"\.lnk", r"\.tfoot \.lnk", r"\.tfoot button"], True),
    ("the GitHub link in .tfoot (.tfoot a)", [r"\.tfoot a"], True),
]
other = [
    ("the peek's links (.acts a)", [r"(\.peek )?\.acts a"], True),
    ("the sub-toggle (.subtoggle)", [r"\.subtoggle"], True),
]
check("AC-1 every Factory control declares a 24x24px box", [target(*t) for t in factory])
check("AC-2 the peek and the drawer controls declare a 24x24px box", [target(*t) for t in other])

# no fixed height under 24px on a button, a, select, input or summary; no target drawn by a pseudo-element
small, pseudo = [], []
for sels, b in rules:
    for sel in sels:
        if "::" in sel:
            if re.search(r"::(before|after)$", sel) and re.search(r"(\.views|\.sumline|\.proj select|\.lnk|\.subtoggle|\.acts|\.tfoot|a\.cap)", sel) and re.search(r"(?<![\w-])(min-)?(height|width)\s*:", b):
                pseudo.append(sel)
            continue
        tok = re.split(r"[\s>+~]+", sel)[-1]
        if not re.match(r"^(button|a|select|input|summary)(?![\w-])", tok): continue
        for prop in ("height", "max-height"):
            v = px(last(b, prop))
            if v is not None and v < 24: small.append(f"{sel} {prop}: {v:g}px")
check("AC-2 no button, a, select, input or summary has a height under 24px",
      [("fixed height under 24px: " + "; ".join(small)) if small else None,
       ("a target is made by a pseudo-element: " + "; ".join(pseudo)) if pseudo else None])

# ---- AC-4: the switch
def line(name):
    m = re.search(r"^[ \t]*const " + name + r" = .*$", h, re.M)
    return m.group(0) if m else ""
WORDS = '<span class="sw-w" aria-hidden="true"><b>On</b><b>Off</b></span><i></i>'
def template(name, key):
    t = line(name)
    if not t: return [f"{name}() is not found in the page"]
    p = []
    if 'role="switch"' not in t: p.append(f'{name}() writes no role="switch"')
    if not re.search(r'aria-checked=["\']?\$\{', t): p.append(f"{name}() writes no aria-checked bound to the state")
    if WORDS not in t: p.append(f"{name}() has no {WORDS} before the end of the switch")
    if key not in t: p.append(f"{name}() lost {key}")
    if "aria-label" not in t: p.append(f"{name}() lost aria-label")
    return p
check("AC-4 the pause switch (sw) is role=switch with aria-checked and the On/Off word", template("sw", "data-pause"))
check("AC-4 the Settings flip (flip) is role=switch with aria-checked and the On/Off word", template("flip", "data-nk"))

m = re.search(r'document\.addEventListener\("change".*?\n\}\);', h, re.S)
ch = m.group(0) if m else ""
check("AC-4 the delegated change listener writes aria-checked for input[role=switch]",
      [None if ch else "no delegated document change listener",
       None if ch and "aria-checked" in ch and re.search(r"role\s*=\s*[\"']?switch|role=\\?[\"']switch", ch) else
       "the change listener does not set aria-checked on an input[role=\"switch\"]"])

word = [(sels, b) for sels, b in rules if any("sw-w" in x for x in sels)]
hide = [b for sels, b in word if any(re.search(r"input:checked\s*~\s*\.sw-w", x) for x in sels)]
check("AC-4 CSS picks the word by input:checked ~ .sw-w with visibility hidden, not with content",
      [None if hide else "no rule on input:checked ~ .sw-w",
       None if hide and any("visibility" in b and "hidden" in b for b in hide) else "no visibility: hidden on the word that does not apply",
       "a .sw-w rule uses content:" if any(re.search(r"(?<![\w-])content\s*:", b) for _, b in word) else None])
check("AC-4 the catalog has On -> Ligado and Off -> Desligado under exact",
      [None if exact.get("On") == "Ligado" else f'catalog exact "On" is {exact.get("On")!r}, not "Ligado"',
       None if exact.get("Off") == "Desligado" else f'catalog exact "Off" is {exact.get("Off")!r}, not "Desligado"'])

# ---- AC-6: no text under 12px
under = []
for m in re.finditer(r"(?<![\w-])font-size\s*[:=]\s*[\"']?\s*([\d.]+)\s*(px|rem|em|pt)?", h):
    v, u = float(m.group(1)), m.group(2) or "px"
    size = v * 16 if u == "rem" else v * 4 / 3 if u == "pt" else v
    if u == "em": continue
    if size < 12: under.append(f"font-size {m.group(1)}{u}")
for m in re.finditer(r"(?<![\w-])font\s*:\s*([^;}\"`]*)", h):
    for tok in m.group(1).split():
        t = re.match(r"^([\d.]+)(px|rem)(?:/.*)?$", tok)
        if t:
            size = float(t.group(1)) * (16 if t.group(2) == "rem" else 1)
            if size < 12: under.append(f"font {tok}")
            break
check("AC-6 no font-size, font shorthand, inline style or SVG attribute is under 12px",
      [("under 12px: " + ", ".join(sorted(set(under)))) if under else None])

cap = [".cap", ".views button", ".isec h3", ".iq-k", ".sgroup > h2"]
probs = []
for sel in cap:
    bs = bodies(re.escape(sel))
    if not bs: probs.append(f"{sel}: no rule"); continue
    body = " ".join(bs)
    if px(last(body, "font-size")) != 12: probs.append(f"{sel}: font-size is {last(body, 'font-size')}, not 12px")
    ls = (last(body, "letter-spacing") or "").replace("0.1em", ".1em")
    if ls != ".1em": probs.append(f"{sel}: letter-spacing is {last(body, 'letter-spacing')}, not 0.1em")
    if re.search(r"\.14em", body): probs.append(f"{sel}: still has .14em")
check("AC-6 the Caption rules are 12px with 0.1em tracking", probs)

sys.stdout.reconfigure(encoding="ascii", errors="backslashreplace")
for name, bad in res:
    print(("PASS " + name) if not bad else ("FAIL " + name + ": " + "; ".join(bad)))
PY
)"
if [ -z "$out" ]; then fail "the check printed nothing"; fi
while IFS= read -r line; do
  case "$line" in
    PASS\ *) pass "${line#PASS }" ;;
    FAIL\ *) fail "${line#FAIL }" ;;
    *) fail "unexpected output: $line" ;;
  esac
done <<< "$out"
finish
