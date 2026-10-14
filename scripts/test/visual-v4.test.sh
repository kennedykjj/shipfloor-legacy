#!/usr/bin/env bash
# suite: integration
# The visual system v4 (#180): IBM Plex embedded and nothing from the network (AC-3), no uppercase transforms beyond
# the exceptions DESIGN.md lists (AC-4), no text under 12px, and the font license cited and shipped (AC-8).
# AC-5 (byte growth in the PR body) and AC-6 (nothing clipped) are checked by hand in review.
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$FACTORY_DIR/.." && pwd)"
out="$("$FACTORY_PYTHON" -I - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
rd = lambda p: open(os.path.join(root, p), encoding="utf-8", newline=None).read()
html = rd("scripts/dashboard.html")
design = rd("DESIGN.md")
readme = rd("README.md")
res = []
def check(name, cond, why): res.append(("PASS " + name) if cond else ("FAIL " + name + ": " + why))

# ---- AC-3: the fonts
style = html[html.index("<style>") + 7:html.index("</style>")]
faces = re.findall(r"@font-face\s*\{([^}]*)\}", style)
def face(b):
    fam = re.search(r"font-family\s*:\s*[\"']?([^\"';]+?)[\"']?\s*;", b)
    w = re.search(r"font-weight\s*:\s*(\d+)", b)
    s = re.search(r"font-style\s*:\s*(\w+)", b)
    return (fam.group(1).strip() if fam else "", w.group(1) if w else "400", s.group(1) if s else "normal", b)
fs = [face(b) for b in faces]
def count(fam, w, st):
    return [b for f, ww, ss, b in fs if f == fam and ww == w and ss == st]
want = [("IBM Plex Sans", "400", "normal"), ("IBM Plex Sans", "500", "normal"), ("IBM Plex Sans", "600", "normal"), ("IBM Plex Sans", "400", "italic"),
        ("IBM Plex Mono", "400", "normal"), ("IBM Plex Mono", "500", "normal")]
for fam, w, st in want:
    bs = count(fam, w, st)
    label = f"{fam} {w}{' italic' if st == 'italic' else ''}"
    check(f"AC-3 {label} is embedded as a woff2 data URI, latin and latin-ext", len(bs) >= 2 and all(re.search(r"url\(\s*[\"']?data:(?:font|application)/(?:x-)?woff2;base64,[A-Za-z0-9+/=]{200,}", b) for b in bs) and sum("unicode-range" in b for b in bs) >= 2,
          f"{len(bs)} @font-face rule(s) for it; want a latin and a latin-ext one, each with unicode-range and a woff2 base64 data URI")
check("AC-3 the faces use font-display: swap", bool(fs) and all("font-display" in b and "swap" in b for _, _, _, b in fs), "an @font-face rule has no font-display: swap")
check("AC-3 no Barlow face is left", not any("Barlow" in f for f, _, _, _ in fs) and not re.search(r"font-family\s*:\s*\"?Barlow", style), "Barlow is still declared")
sans = re.search(r"--sans\s*:\s*([^;]+);", style); mono = re.search(r"--mono\s*:\s*([^;]+);", style)
check("AC-3 --sans starts with IBM Plex Sans and falls back to system-ui", bool(sans) and sans.group(1).strip().startswith(('"IBM Plex Sans"', "'IBM Plex Sans'")) and "system-ui" in sans.group(1), f"--sans is {sans.group(1).strip() if sans else 'missing'}")
check("AC-3 --mono starts with IBM Plex Mono and falls back to ui-monospace", bool(mono) and mono.group(1).strip().startswith(('"IBM Plex Mono"', "'IBM Plex Mono'")) and "ui-monospace" in mono.group(1), f"--mono is {mono.group(1).strip() if mono else 'missing'}")
check("AC-3 --cond is gone", "--cond" not in html, "--cond is still used")
urls = re.findall(r"url\(\s*[\"']?([^)\"']*)", style)
net = [u[:50] for u in urls if not u.startswith(("data:", "#", "%23"))]
check("AC-3 every CSS url() is a data URI", not net, f"url() reaches out: {net[:3]}")
check("AC-3 no @import", "@import" not in style, "the css has an @import")
links = [t for t in re.findall(r"<(?:link|script|img|iframe|source)\b[^>]*>", html, flags=re.I) if re.search(r"\b(?:src|href)\s*=\s*[\"']?(?:https?:)?//", t, flags=re.I)]
check("AC-3 no tag loads anything from the network", not links, f"tags with a network src/href: {[l[:80] for l in links[:3]]}")
check("AC-3 no font service named", not re.search(r"fonts\.(?:googleapis|gstatic)|fontsource|cdn\.|jsdelivr|unpkg", html, flags=re.I), "the page names a font service or CDN")

# ---- AC-4: no uppercase beyond the exceptions DESIGN.md lists
css = re.sub(r"/\*.*?\*/", "", re.sub(r"@font-face\s*\{[^}]*\}", "", style), flags=re.S)
rules = [(re.sub(r"\s+", " ", s).strip(), b) for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", css)]
upper = [s for s, b in rules if re.search(r"text-transform\s*:\s*uppercase", b)]
other = len(re.findall(r"text-transform\s*:\s*uppercase", html)) - len(upper)
exc_lines = [l for l in design.splitlines() if re.search(r"uppercase", l, flags=re.I) and re.search(r"exception", l, flags=re.I)]
exc_text = " ".join(exc_lines)
unlisted = [s for s in upper if f"`{s}`" not in exc_text and not any(f"`{p.strip()}`" in exc_text for p in s.split(","))]
check("AC-4 text-transform: uppercase appears only on selectors DESIGN.md lists as exceptions", not unlisted and other == 0,
      f"{len(unlisted) + other} uppercase rule(s) not listed as an exception in DESIGN.md: {', '.join(unlisted[:4])}")

# ---- no font-size under 12px
small = []
for m in re.finditer(r"font-size\s*:\s*(\d*\.?\d+)(px|rem|em)\b", html):
    v = float(m.group(1)) * (16 if m.group(2) != "px" else 1)
    if v < 12: small.append(m.group(0))
for m in re.finditer(r"(?<![\w-])font\s*:\s*(?:[\w.-]+\s+)*?(\d*\.?\d+)(px|rem|em)\b", style):
    v = float(m.group(1)) * (16 if m.group(2) != "px" else 1)
    if v < 12: small.append(m.group(0)[:40])
for m in re.finditer(r"font-size=[\"'](\d*\.?\d+)(?:px)?[\"']", html):
    if float(m.group(1)) < 12: small.append(m.group(0))
check("AC-4 no font-size under 12px in dashboard.html", not small, f"{len(small)} under 12px: {sorted(set(small))[:6]}")

# ---- AC-8: the license is cited and shipped
check("AC-8 the README cites scripts/fonts/OFL.txt", "scripts/fonts/OFL.txt" in readme, "README.md never names scripts/fonts/OFL.txt")
p = os.path.join(root, "scripts/fonts/OFL.txt")
ofl = open(p, encoding="utf-8", errors="replace").read() if os.path.isfile(p) else ""
check("AC-8 scripts/fonts/OFL.txt exists", os.path.isfile(p), "scripts/fonts/OFL.txt is missing")
check("AC-8 OFL.txt is the SIL Open Font License for IBM Plex", bool(ofl) and "SIL OPEN FONT LICENSE VERSION 1.1" in ofl.upper().replace("\n", " ") and "IBM" in ofl and len(ofl) > 3000, "OFL.txt does not hold the SIL OFL 1.1 text with the IBM copyright")
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
