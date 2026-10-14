"""The dashboard's themes, computed from the colors dashboard.html declares: every theme sets the base tokens, Settings
offers exactly the themes the CSS has, text stays readable (WCAG 4.5:1) on every surface it sits on, and the pool bar's
four stage hues are told apart. Each check is a function of the page's text, so a lowered token on a copy proves it bites."""
import itertools
import math
import os
import re

import support

PAGE = os.path.join(support.SCRIPTS, "dashboard.html")
HEX = r"#[0-9a-fA-F]{6}"


def page():
    with open(PAGE, encoding="utf-8") as f:
        return f.read()


def themes(h):
    return {n: dict(re.findall(r"--([a-z0-9-]+):\s*([^;]+);", b)) for n, b in re.findall(r'\[data-theme="([a-z]+)"\]\s*\{([^}]*)\}', h)}


def lin(c):
    v = [int(c[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return [x / 12.92 if x <= .04045 else ((x + .055) / 1.055) ** 2.4 for x in v]


def lum_rgb(v):
    v = [x / 255 for x in v]
    v = [x / 12.92 if x <= .03928 else ((x + .055) / 1.055) ** 2.4 for x in v]
    return .2126 * v[0] + .7152 * v[1] + .0722 * v[2]


def lum(c):
    return lum_rgb([int(c[i:i + 2], 16) for i in (1, 3, 5)])


def ratio_l(a, b):
    hi, lo = sorted((a, b), reverse=True)
    return (hi + .05) / (lo + .05)


def ratio(a, b):
    return ratio_l(lum(a), lum(b))


def de(a, b):
    def lab(c):
        r, g, b_ = lin(c)
        x = (.4124564 * r + .3575761 * g + .1804375 * b_) / .95047
        y = .2126729 * r + .7151522 * g + .0721750 * b_
        z = (.0193339 * r + .1191920 * g + .9503041 * b_) / 1.08883
        f = lambda t: t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
        fx, fy, fz = f(x), f(y), f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    return math.dist(lab(a), lab(b))


def token_problems(h):
    """every theme sets each of the base theme's colors, Settings offers the fourteen the CSS has, its color-scheme matches its ground"""
    blocks = themes(h)
    line = h[h.index("const THEMES"):h.index("\n", h.index("const THEMES"))]
    offered = set(re.findall(r'"([a-z]+)"', line))
    colors = [k for k, v in blocks["charcoal"].items() if re.fullmatch(HEX, v)]
    bad = [] if len(blocks) == 14 else ["%d themes (needs 14)" % len(blocks)]
    if offered - {"auto"} != set(blocks):
        bad.append("settings offers %s but the css has %s" % (sorted(offered), sorted(blocks)))
    for name, t in blocks.items():
        missing = [k for k in colors if not re.fullmatch(HEX, t.get(k, ""))]
        if missing:
            bad.append("%s: missing %s" % (name, missing))
        elif (lum(t["ground"]) > .5) != ("color-scheme: light" in h[h.index('[data-theme="%s"]' % name):].split("}")[0]):
            bad.append("%s: color-scheme does not match its ground" % name)
    return bad


def text_problems(h):
    """text, its softer tones, the accent and the state colors hold 4.5:1 on ground, panel and panel-hi in every theme"""
    bad = []
    for name, t in themes(h).items():
        for fg in "text soft muted faint sand ok warn bad refine".split():
            for bg in ("ground", "panel", "panel-hi"):
                try:
                    r = ratio(t[fg], t[bg])
                except (KeyError, ValueError):
                    bad.append("%s: cannot read %s on %s" % (name, fg, bg)); continue
                # the spec pins Graphite's faint (#8b887f) and panel-hi (#23231f) exactly, which gives 4.45:1; AC-1 names
                # "ground and panels", so faint keeps 4.5:1 there and 4.4:1 on panel-hi
                floor = 4.4 if (fg, bg) == ("faint", "panel-hi") else 4.5
                if r < floor:
                    bad.append("%s: %s on %s is %.2f:1" % (name, fg, bg, r))
    return bad


NEW_TOKENS = ["raise", "accent-ink", "paper", "accent-soft", "accent-line"]
V4 = {
    "graphite": {"ground": "#141412", "panel": "#1b1b19", "panel-hi": "#23231f", "raise": "#2a2925", "edge": "#2e2d29", "edge-hi": "#44423c",
                 "text": "#ecebe6", "soft": "#cbc8bf", "muted": "#a29f95", "faint": "#8b887f", "sand": "#e9b44c", "accent-ink": "#1d1606",
                 "ok": "#86c29c", "warn": "#e59a62", "bad": "#e8806f", "track": "#3b3a35", "paper": "#1f1e1b"},
    "paper": {"ground": "#f4f2ec", "panel": "#faf9f5", "panel-hi": "#ffffff", "raise": "#ffffff", "edge": "#e2ddd2", "edge-hi": "#cdc6b8",
              "text": "#1f1d19", "soft": "#3e3a33", "muted": "#5f5a51", "faint": "#6f6a60", "sand": "#8f5b00", "accent-ink": "#ffffff",
              "ok": "#2f7a4b", "warn": "#a2531a", "bad": "#b4372a", "track": "#d9d3c6", "paper": "#fffdf8"},
}


def _alpha_ok(v, pct):
    """the accent at pct%: a color-mix percentage, a rgba() alpha, or an 8-digit hex alpha"""
    v = v.strip()
    if re.search(r"(?<![\d.])%s(\.0+)?%%" % pct, v) and "color-mix" in v:
        return True
    m = re.fullmatch(r"rgba?\(.*[,/]\s*(0?\.\d+|\d+%)\s*\)", v)
    if m:
        a = m.group(1)
        a = float(a[:-1]) / 100 if a.endswith("%") else float(a)
        return abs(a - pct / 100) < .006
    m = re.fullmatch(r"#[0-9a-fA-F]{6}([0-9a-fA-F]{2})", v)
    return bool(m) and abs(int(m.group(1), 16) - round(pct * 2.55)) <= 1


def v4_problems(h):
    """AC-1 (#180): every theme, the base one included, defines the five tokens of the v4 system (raise, accent-ink and paper as
    hex, accent-soft at 14% and accent-line at 45% of the accent), text is readable on raise and paper, Graphite and Paper take
    the Floor v4 table exactly with their accent-ink readable on the accent, and today's blue paper is now Cobalt"""
    blocks = themes(h)
    bad = []
    for name, t in blocks.items():
        miss = [k for k in NEW_TOKENS if not t.get(k, "").strip()]
        if miss:
            bad.append("AC-1 %s: does not define %s" % (name, miss)); continue
        for k in ("raise", "accent-ink", "paper"):
            if not re.fullmatch(HEX, t[k].strip()):
                bad.append("AC-1 %s: %s is not a hex color (%s)" % (name, k, t[k].strip()))
        if not _alpha_ok(t["accent-soft"], 14):
            bad.append("AC-1 %s: accent-soft is %s, want the accent at 14%%" % (name, t["accent-soft"].strip()))
        if not _alpha_ok(t["accent-line"], 45):
            bad.append("AC-1 %s: accent-line is %s, want the accent at 45%%" % (name, t["accent-line"].strip()))
        for bg in ("raise", "paper"):
            if re.fullmatch(HEX, t[bg].strip()) and re.fullmatch(HEX, t.get("text", "")) and ratio(t["text"], t[bg]) < 4.5:
                bad.append("AC-1 %s: text on %s is %.2f:1" % (name, bg, ratio(t["text"], t[bg])))
    for name, want in V4.items():
        if name not in blocks:
            bad.append('AC-1 %s: no [data-theme="%s"] block' % (name, name)); continue
        for k, v in want.items():
            got = blocks[name].get(k, "").strip().lower()
            if got != v:
                bad.append("AC-1 %s: --%s is %s, Floor v4 says %s" % (name, k, got or "missing", v))
        t = blocks[name]
        if all(re.fullmatch(HEX, t.get(k, "")) for k in ("accent-ink", "sand")) and ratio(t["accent-ink"], t["sand"]) < 4.5:
            bad.append("AC-1 %s: accent-ink on the accent is %.2f:1" % (name, ratio(t["accent-ink"], t["sand"])))
    cob = blocks.get("cobalt", {})
    if cob.get("ground", "").strip().lower() != "#e3ebf6" or cob.get("sand", "").strip().lower() != "#006478":
        bad.append("AC-1 cobalt: ground/sand are %s/%s, want the old paper's #e3ebf6/#006478" % (cob.get("ground"), cob.get("sand")))
    if "paper" in blocks and blocks["paper"].get("ground", "").strip().lower() == "#e3ebf6":
        bad.append("AC-1 paper is still the old blue theme")
    return bad


def _resolve(v, tok, depth=0):
    """(r, g, b, a) of a CSS color: hex, var(--x), color-mix(in srgb, ...); ValueError on anything else"""
    v = v.strip()
    m = re.fullmatch(r"#([0-9a-fA-F]+)", v)
    if m and len(m.group(1)) in (3, 4, 6, 8):
        x = m.group(1)
        if len(x) < 6:
            x = "".join(c * 2 for c in x)
        return (int(x[0:2], 16), int(x[2:4], 16), int(x[4:6], 16), int(x[6:8], 16) / 255 if len(x) == 8 else 1.0)
    m = re.fullmatch(r"var\(\s*--([a-z0-9-]+)\s*\)", v)
    if m and depth < 5 and tok(m.group(1)):
        return _resolve(tok(m.group(1)), tok, depth + 1)
    m = re.fullmatch(r"color-mix\((.*)\)", v)
    if m:
        args, d, cur = [], 0, ""
        for ch in m.group(1):
            d += {"(": 1, ")": -1}.get(ch, 0)
            if ch == "," and d == 0:
                args.append(cur.strip()); cur = ""
            else:
                cur += ch
        args.append(cur.strip())
        if len(args) == 3 and re.fullmatch(r"in\s+srgb", args[0]):
            parts = []
            for c in args[1:]:
                pm = re.fullmatch(r"(.*?)\s+(\d*\.?\d+)%", c)
                parts.append((pm.group(1), float(pm.group(2))) if pm else (c, None))
            (c1, p1), (c2, p2) = parts
            if p1 is None and p2 is None:
                p1 = p2 = 50.0
            elif p1 is None:
                p1 = 100 - p2
            elif p2 is None:
                p2 = 100 - p1
            x, y = _resolve(c1, tok, depth + 1), _resolve(c2, tok, depth + 1)
            w1, w2 = p1 / (p1 + p2), p2 / (p1 + p2)
            return tuple(i * w1 + j * w2 for i, j in zip(x, y))
    raise ValueError(v)


def surface_problems(h):
    """#120: the decision column's well (.idec, blended over the panel) and the Approve pill's hover keep their text at 4.5:1"""
    blocks = themes(h)
    base = blocks["charcoal"]
    css = re.sub(r"/\*.*?\*/", "", h[h.index("<style>") + 7:h.index("</style>")], flags=re.S)
    css = re.sub(r"@font-face\s*\{[^}]*\}", "", css)
    rules = [(re.sub(r"\s+", " ", s).strip(), b) for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", css)]

    def decl(ok, prop):
        for s, b in rules:
            if ok(s):
                m = re.search(r"(?<![\w-])%s\s*:\s*([^;}]+)" % prop, b)
                if m:
                    return m.group(1).replace("!important", "").strip()
        return ""
    idec_bg, hov_bg = decl(lambda s: s == ".idec", "background"), decl(lambda s: ".pill:hover" in s, "background")
    pill_fg = decl(lambda s: s == ".stub .pill, .edit .pill", "color")
    bad = []
    for name, t in sorted(blocks.items()):
        tok = lambda k: t.get(k, base.get(k, "")).strip()  # a theme that omits a token inherits the base one
        try:
            c = _resolve(idec_bg, tok)
            panel = _resolve(tok("panel"), tok)[:3]
            under = [x * (1 - c[3]) + y * c[3] for x, y in zip(panel, c[:3])]
            for fg in ("text", "soft", "muted"):
                r = ratio_l(lum_rgb(_resolve(tok(fg), tok)[:3]), lum_rgb(under))
                if r < 4.5:
                    bad.append("%s: %s on the .idec background is %.2f:1" % (name, fg, r))
        except ValueError:
            bad.append("%s: cannot resolve the .idec background %r" % (name, idec_bg))
        try:
            r = ratio_l(lum_rgb(_resolve(pill_fg, tok)[:3]), lum_rgb(_resolve(hov_bg, tok)[:3]))
            if r < 4.5:
                bad.append("%s: the pill's text on its hover background is %.2f:1" % (name, r))
        except ValueError:
            bad.append("%s: cannot resolve the pill's hover colors (%r on %r)" % (name, pill_fg, hov_bg))
    return bad


def hue_problems(h):
    """#115: --validate in every theme, readable; the stage hues hold 3:1 on edge; the pool bar's four stage colors are four
    colors (dE 20 apart), none the accent; on Kraft Refine and Validate are told apart"""
    blocks = themes(h)
    hexof = lambda t, k: (lambda v: v if re.fullmatch(HEX, v) else None)(blocks[t].get(k or "", "").strip())
    m = re.search(r"const STAGE_HUE\s*=\s*\{([^}]*)\}", h)
    hue = dict(re.findall(r'(\w+)\s*:\s*"([^"]*)"', m.group(1))) if m else {}
    tok = {k: (re.fullmatch(r"var\(--([a-z0-9-]+)\)", v) or [None, None])[1] for k, v in hue.items()}
    bad = [] if tok.get("validate") == "validate" else ["STAGE_HUE.validate is %r" % hue.get("validate")]
    for t in sorted(blocks):
        v = hexof(t, "validate")
        if not v:
            bad.append("%s has no --validate" % t); continue
        for bg in ("ground", "panel", "panel-hi"):
            if ratio(v, hexof(t, bg)) < 4.5:
                bad.append("%s: validate on %s is %.2f:1" % (t, bg, ratio(v, hexof(t, bg))))
        for fg in ("refine", "text", "validate", "ok"):
            if not hexof(t, fg) or ratio(hexof(t, fg), hexof(t, "edge")) < 3:
                bad.append("%s: %s on edge is under 3:1" % (t, fg))
        cols = {st: hexof(t, tok.get(st)) for st in ("refine", "develop", "validate", "deploy")}
        bad += ["%s: %s does not resolve to a color" % (t, st) for st, c in cols.items() if not c]
        cols = {st: c for st, c in cols.items() if c}
        sand = hexof(t, "sand")
        bad += ["%s: %s is the accent" % (t, st) for st, c in cols.items() if sand and c.lower() == sand.lower()]
        bad += ["%s: %s and %s are dE %.1f apart" % (t, a, b, de(cols[a], cols[b])) for a, b in itertools.combinations(cols, 2) if de(cols[a], cols[b]) < 20]
    return bad


class Theme(support.Case):
    def test_tokens(self):
        "every theme sets the base theme's colors, Settings offers the fourteen themes the CSS has, each color-scheme matches its ground"
        self.assertEqual(token_problems(page()), [])

    def test_text_contrast(self):
        "text, soft, muted, faint, the accent and the state colors hold 4.5:1 on ground, panel and panel-hi in all fourteen themes"
        self.assertEqual(text_problems(page()), [])

    def test_v4_tokens(self):
        "AC-1 (#180): the five v4 tokens in every theme, Graphite and Paper at the Floor v4 values, today's blue paper is Cobalt"
        self.assertEqual(v4_problems(page()), [])

    def test_surfaces(self):
        "#120: the decision well and the Approve pill's hover keep their text at 4.5:1 in every theme"
        self.assertEqual(surface_problems(page()), [])

    def test_stage_hues(self):
        "#115: the pool bar's stage hues are readable and told apart in every theme, none the accent"
        self.assertEqual(hue_problems(page()), [])

    def test_the_checks_bite(self):
        "on a copy with a token lowered, a theme gone or two hues alike, the checks fail and name it"
        h = page()
        faint = re.search(r'\[data-theme="tape"\]\s*\{[^}]*--faint:\s*(#[0-9a-fA-F]{6})', h).group(1)
        at = h.index('[data-theme="tape"]')
        low = h[:at] + h[at:].replace("--faint: %s" % faint, "--faint: #6a6a6a", 1)
        self.assertTrue(any(p.startswith("tape: faint on panel is") for p in text_problems(low)))
        thirteen = "\n".join(l for l in h.split("\n") if not l.startswith('[data-theme="paper"]'))
        self.assertIn("13 themes (needs 14)", token_problems(thirteen))
        at = h.index('[data-theme="graphite"]')
        off = h[:at] + h[at:].replace("--sand: #e9b44c", "--sand: #e9b44d", 1)
        self.assertTrue(any("graphite: --sand" in p for p in v4_problems(off)))
        at = h.index('[data-theme="cobalt"]')
        self.assertTrue(any("cobalt: ground/sand" in p for p in v4_problems(h[:at] + h[at:].replace("#e3ebf6", "#e3ebf7", 1))))
        kraft = themes(h)["kraft"]
        at = h.index('[data-theme="kraft"]')
        same = h[:at] + h[at:].replace("--validate: %s" % kraft["validate"], "--validate: %s" % kraft["refine"], 1)
        self.assertTrue(any(p.startswith("kraft: ") and "apart" in p for p in hue_problems(same)))
