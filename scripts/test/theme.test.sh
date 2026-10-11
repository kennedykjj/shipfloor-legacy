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
if offered != set(blocks): bad.append(f"settings offers {sorted(offered)} but the css has {sorted(blocks)}")
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
finish
