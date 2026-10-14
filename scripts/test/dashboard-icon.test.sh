#!/usr/bin/env bash
# The mark: the dashboard's header and tab icon draw the same route as docs/img/icon.svg, painted with the theme's tokens.
# Its colors are --sand and --text on --ground, which theme.test.sh holds at 4.5:1 in every theme.
source "$(dirname "$0")/lib.sh"
root="$FACTORY_DIR/.."
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$root/docs/img/icon.svg" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
svg = open(sys.argv[2], encoding="utf-8").read()
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
def geometry(s):  # the route's d and the card's box, wherever they are drawn
    d = re.search(r'<path d="([^"]+)"', s); r = re.search(r'<rect x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)"', s)
    return (d.group(1) if d else None, r.groups() if r else None)
m = re.search(r"const MARK = '([^']*)'", h)
hd = re.search(r'<span class="g brand">(<svg class="mark".*?</svg>)Shipfloor</span>', h)
icon, tab, head = geometry(svg), geometry(m.group(1) if m else ""), geometry(hd.group(1) if hd else "")
check("the page links a tab icon the script paints", '<link rel="icon" id="favicon"' in h, 'no <link rel="icon" id="favicon">')
check("the header carries the mark before the name", bool(hd), "no svg.mark inside the brand")
check("docs/img/icon.svg draws the route and the card", None not in icon, f"read {icon}")
check("the tab icon draws the same route as docs/img/icon.svg", tab == icon, f"tab {tab}, icon {icon}")
check("the header draws the same route as docs/img/icon.svg", head == icon, f"header {head}, icon {icon}")
f = h[h.find("function favicon"):h.find("\n}\n", h.find("function favicon"))]
check("the tab icon takes ground, sand and text from the theme", all(f'v("{k}")' in f for k in ("ground", "sand", "text")), "favicon() does not read all three tokens")
t = h[h.find("function theme("):h.find("\n}\n", h.find("function theme("))]
check("every theme change repaints the tab icon", "favicon()" in t, "theme() does not call favicon()")
tape = dict(re.findall(r"--([a-z-]+):\s*(#[0-9a-fA-F]{6})", re.search(r'\[data-theme="tape"\]\s*\{([^}]*)\}', h).group(1)))
want = [tape["ground"], tape["sand"], tape["text"]]
check("docs/img/icon.svg is the Floor tape theme", all(c.lower() in svg.lower() for c in want), f"want {want}")
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
