#!/usr/bin/env bash
# The accent marks only a card that waits for the owner: a queued waiting tile is neutral, an infrastructure block is warn
# like the Lifecycle band's dot, and the waiting tile takes its kind from kindOf (#115).
# Static: reads the CSS and JS of dashboard.html as text and resolves the cascade for the marks of a waiting tile.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
css = "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", h, re.S))
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)

def match_brace(s, i):
    d = 0
    for j in range(i, len(s)):
        if s[j] == "{": d += 1
        elif s[j] == "}":
            d -= 1
            if d == 0: return j
    return len(s) - 1

def split_top(s, sep):
    parts, d, cur = [], 0, ""
    for ch in s:
        if ch == "(": d += 1
        elif ch == ")": d -= 1
        if ch == sep and d == 0: parts.append(cur); cur = ""
        else: cur += ch
    return parts + [cur]

rules, i = [], 0   # (selector, [(prop, value)]) in source order, at-rules skipped
while True:
    o = css.find("{", i)
    if o < 0: break
    head = css[i:o].strip()
    c = match_brace(css, o)
    if not head.startswith("@"):
        ds = []
        for d in split_top(css[o + 1:c], ";"):
            if ":" in d:
                k, v = d.split(":", 1)
                ds.append((k.strip().lower(), " ".join(v.split())))
        for s in split_top(head, ","):
            if s.strip(): rules.append((" ".join(s.split()), ds))
    i = c + 1

def comps(sel):
    cs = sel.split()
    out = []
    for c in cs:
        if not re.fullmatch(r"(\.[A-Za-z0-9_-]+)+", c): return None
        out.append(set(c.split(".")[1:]))
    return out

def matches(sel, tile, mark):
    cs = comps(sel)
    if not cs: return False
    target = tile if mark is None else mark
    if not cs[-1] <= target: return False
    anc = cs[:-1]
    if mark is None: return not anc
    chain = [tile, {"thead"}]
    k = 0
    for a in anc:
        while k < len(chain) and not a <= chain[k]: k += 1
        if k == len(chain): return False
        k += 1
    return True

def token(v):
    m = re.search(r"var\(--([a-z0-9-]+)\)", v)
    return m.group(1) if m else None

def resolve(tile, mark, props):
    best = None
    for n, (sel, ds) in enumerate(rules):
        if not matches(sel, tile, mark): continue
        spec = sum(len(c) for c in comps(sel))
        for k, v in ds:
            if k in props:
                key = (spec, n)
                if best is None or key >= best[0]: best = (key, v)
    if best is None: return None
    return token(best[1]) or "(no token: " + best[1] + ")"

COLOR = {"color"}
BORDER = {"border", "border-color"}
FILL = {"background", "background-color"}
WAIT = {"tile", "wait"}
res = []
def check(name, probs):
    res.append("ok|" + name if not probs else "FAIL|" + name + ": " + "; ".join(probs))
def want(probs, label, got, exp):
    if got != exp: probs.append(f"{label} is {('--' + got) if got else 'unset'}, want --{exp}")
def nofill(probs, label, got):
    if got not in (None, "(no token: none)", "(no token: transparent)"): probs.append(f"{label} is filled with {got}, want no fill")

NEUTRAL_BAD = {"sand", "ok", "warn", "bad"}
# AC-1
p = []
want(p, "queued .ring border", resolve(WAIT, {"ring"}, BORDER), "muted")
nofill(p, "queued .ring", resolve(WAIT, {"ring"}, FILL))
want(p, "queued .why color", resolve(WAIT, {"why"}, COLOR), "soft")
want(p, "queued .tnum color", resolve(WAIT, {"tnum"}, COLOR), "muted")
want(p, "queued .ttitle color", resolve(WAIT, {"ttitle"}, COLOR), "muted")
want(p, "just-changed queued tile border", resolve(WAIT | {"ch"}, None, BORDER), "text")
for label, t, m, props in (("tile border", WAIT, None, BORDER), ("ring border", WAIT, {"ring"}, BORDER), ("ring fill", WAIT, {"ring"}, FILL),
                           ("why", WAIT, {"why"}, COLOR), ("tnum", WAIT, {"tnum"}, COLOR), ("ttitle", WAIT, {"ttitle"}, COLOR),
                           ("just-changed tile border", WAIT | {"ch"}, None, BORDER)):
    if resolve(t, m, props) in NEUTRAL_BAD: p.append(f"queued {label} resolves to --{resolve(t, m, props)}, an accent or outcome color")
check("AC-1 a queued waiting tile has neutral marks: muted ring, soft reason, no accent or outcome color", p)

# AC-2
p = []
t = WAIT | {"infra"}
want(p, "infra .ring background", resolve(t, {"ring"}, FILL), "warn")
want(p, "infra .ring border", resolve(t, {"ring"}, BORDER), "warn")
want(p, "infra .tnum color", resolve(t, {"tnum"}, COLOR), "warn")
want(p, "infra .why color", resolve(t, {"why"}, COLOR), "warn")
want(p, "infra .ttitle color", resolve(t, {"ttitle"}, COLOR), "muted")
want(p, "infra tile border", resolve(t, None, BORDER), "edge-hi")
check("AC-2 an infrastructure tile has a warn ring, number and reason", p)

# AC-3
def dot(sel, prop):
    for s, ds in rules:
        if s == sel:
            for k, v in ds:
                if k == prop: return token(v)
    return None
di, de = dot(".dot.infra i", "background"), dot(".dot.infra em", "color")
p = []
if not di or di != de: p.append(f"the band's .dot.infra uses --{di} for the dot and --{de} for the number; they should be one token")
else:
    want(p, "infra .ring background (the band's dot color)", resolve(t, {"ring"}, FILL), di)
    want(p, "infra .ring border (the band's dot color)", resolve(t, {"ring"}, BORDER), di)
    want(p, "infra .tnum color (the band's number color)", resolve(t, {"tnum"}, COLOR), de)
    want(p, "infra .why color (the band's number color)", resolve(t, {"why"}, COLOR), de)
w = h.find("const waits")
tw = h.find('class="tile wait', w if w >= 0 else 0)
win = h[w:tw + 300] if w >= 0 and tw >= 0 else ""
if not win: p.append("renderWork's waiting tile (const waits ... class=\"tile wait\") was not found")
else:
    if not re.search(r"kindOf\(\s*key\(c\)\s*,\s*c\s*\)", win): p.append("the waiting tile does not read kindOf(key(c), c)")
    cls = re.search(r'class="tile wait([^"]*)"', h[tw:])
    inner = cls.group(1) if cls else ""
    if "infra" not in win or not re.search(r"\byou\b", win): p.append("the waiting tile's class never names infra and you")
    if re.search(r"\$\{\s*(kind|kindOf\([^)]*\))\s*\}", inner): p.append("the waiting tile's class interpolates the whole kind; only infra and you may be added")
check("AC-3 the infrastructure tile uses the band's dot color and its class comes from kindOf", p)

# AC-4
p = []
for label, t, m, props in (("queued ring", WAIT, {"ring"}, BORDER | FILL), ("queued why", WAIT, {"why"}, COLOR), ("queued tnum", WAIT, {"tnum"}, COLOR)):
    if resolve(t, m, props) == "sand": p.append(f"{label} resolves to --sand")
yt = WAIT | {"you"}
want(p, "owner tile .ring border", resolve(yt, {"ring"}, BORDER), "sand")
want(p, "owner tile .ring background", resolve(yt, {"ring"}, FILL), "sand")
want(p, "owner tile .tnum color", resolve(yt, {"tnum"}, COLOR), "sand")
want(p, "owner tile .why color", resolve(yt, {"why"}, COLOR), "sand")
for sel, ds in rules:
    cs = comps(sel)
    if not cs: continue
    mark_rule = cs[-1] & {"ring", "why", "tnum", "ttitle"} or ("wait" in cs[-1] and "tile" in cs[-1])
    if mark_rule and any("--sand" in v for k, v in ds) and not any("you" in c for c in cs):
        p.append(f"{sel} gives a waiting-tile mark --sand outside .tile.wait.you")
check("AC-4 the accent marks a waiting tile only when its card waits for the owner", p)
print("\n".join(res))
PY
)"
if [ -z "$out" ]; then fail "the check printed nothing"; fi
while IFS= read -r line; do
  case "$line" in
    ok\|*) pass "${line#ok|}" ;;
    FAIL\|*) fail "${line#FAIL|}" ;;
    *) fail "unexpected output: $line" ;;
  esac
done <<< "$out"
finish
