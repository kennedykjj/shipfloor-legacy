"""The dashboard's v4 visual system (#180), read from the files that carry it: dashboard.html (the Settings theme groups,
the caption and stepper rules), DESIGN.md and its sidecar .impeccable/design.json (what they say about type, color, themes
and shapes, against what the page declares). The theme tokens themselves are in dashboard_theme.py. Every check is a function
of the text it is given, so a test can break a copy and see the check fail."""
import json
import os
import re
import sys

import support

sys.path.insert(0, os.path.join(support.SCRIPTS, "test"))
import page_text  # noqa: E402  the page's text is a catalog by key (#122)

ROOT = os.path.dirname(support.SCRIPTS)
NEG = re.compile(r"\b(?:no|never|not|don't|without|exceptions?|nothing)\b", re.I)


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8", newline=None) as f:
        return f.read()


def page():
    return page_text.english(read("scripts", "dashboard.html"))


def style(h):
    css = h[h.index("<style>") + 7:h.index("</style>")]
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    return re.sub(r"@font-face\s*\{[^}]*\}", "", css)


def rules_of(css):
    return [(re.sub(r"\s+", " ", s).strip(), b) for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", css)]


def last(body, prop):
    vals = re.findall(r"(?<![\w-])" + re.escape(prop) + r"\s*:\s*([^;}]+)", body)
    return vals[-1].strip() if vals else None


def px(v):
    m = re.fullmatch(r"([\d.]+)px", (v or "").strip().lower())
    return float(m.group(1)) if m else None


def norm(v):
    v = v.strip().lower().replace("!important", "").strip()
    m = re.fullmatch(r"(\d*\.?\d+)(px|rem|em|%)", v)
    if not m or float(m.group(1)) == 0 or v == "50%":
        return None
    return "%g%s" % (float(m.group(1)), m.group(2))


# ---- the page: Settings offers Auto, Graphite, Paper, High contrast first (AC-2)

def theme_group_problems(h):
    """THEMES.first is Auto, Graphite, Paper, High contrast; dark and light hold the other eleven; Tape is dark, Kraft and Cobalt
    light; the fourteen themes are each offered once; Auto resolves to Graphite in dark and Paper in light; pt-BR names them"""
    bad = []
    i = h.index("const THEMES")
    win = h[i:i + 900]
    pos = {k: win.find(k + ":") for k in ("first", "dark", "light")}

    def ids(k):
        if pos[k] < 0:
            return []
        later = sorted(p for p in pos.values() if p > pos[k])
        return re.findall(r'"([a-z]+)"', win[pos[k]:later[0] if later else len(win)].split("\n")[0])
    first, dark, light = ids("first"), ids("dark"), ids("light")
    css = set(re.findall(r'\[data-theme="([a-z]+)"\]\s*\{', h))
    rest = dark + light
    if first != ["auto", "graphite", "paper", "contrast"]:
        bad.append("AC-2 THEMES.first is %s, want Auto, Graphite, Paper, High contrast in that order" % first)
    if not (len(rest) == 11 and not set(rest) & set(first)):
        bad.append("AC-2 dark+light are %s, want the other eleven themes, none of the four" % rest)
    if not ("tape" in dark and "kraft" in light and "cobalt" in light):
        bad.append("AC-2 Tape is dark and Kraft and Cobalt are light: dark %s, light %s" % (dark, light))
    if not (sorted(x for x in first + rest if x != "auto") == sorted(css) and len(css) == 14):
        bad.append("AC-2 each of the fourteen themes is offered once: offered %s" % sorted(first + rest))
    if not ("cobalt" in rest and "cobalt" in css):
        bad.append("AC-2 Cobalt is not offered or has no css block")
    fn = re.search(r"function theme\(pick\)\s*\{.*?\n\}", h, flags=re.S)
    auto = next((l for l in (fn.group(0) if fn else "").splitlines() if "dataset.theme" in l), "")
    if not ("graphite" in auto and '"paper"' in auto and "prefers-color-scheme: light" in auto and "kraft" not in auto and "tape" not in auto):
        bad.append("AC-2 Auto does not resolve to Graphite in dark and Paper in light, theme() sets the theme with: %s" % auto.strip())
    if [page_text.msg("pt-BR", k) for k in ("theme.graphite", "theme.paper", "theme.cobalt")] != ["Graphite", "Paper", "Cobalt"]:
        bad.append("AC-2 theme.graphite/paper/cobalt are not Graphite/Paper/Cobalt in pt-BR")
    return bad


# ---- the page: the caption and the stepper

def caption_problems(h):
    """AC-6: the Caption rules are 12px with no tracking"""
    rules = [([re.sub(r"\s+", " ", x).strip() for x in s.split(",")], b) for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", style(h))]
    bad = []
    for sel in (".cap", ".views button", ".isec h3", ".iq-k", ".sgroup > h2"):
        bs = [b for sels, b in rules if sel in sels]
        if not bs:
            bad.append("%s: no rule" % sel); continue
        body = " ".join(bs)
        if px(last(body, "font-size")) != 12:
            bad.append("%s: font-size is %s, not 12px" % (sel, last(body, "font-size")))
        ls = (last(body, "letter-spacing") or "0").strip()
        if ls not in ("0", "0em", "0px", "normal"):
            bad.append("%s: letter-spacing is %s, want no tracking" % (sel, ls))
    return bad


def dirty_stepper_problems(h):
    """AC-7: a dirty stepper's value is --text, not the accent (the accent is for what waits for the owner)"""
    vals = [last(b, "color") for s, b in rules_of(style(h)) if s == ".stp.dirty output"]
    return [] if vals and vals[-1] == "var(--text)" else [".stp.dirty output color is %s, want var(--text)" % (vals[-1] if vals else "missing")]


# ---- DESIGN.md and its sidecar against the page

class Doc:
    def __init__(self, design, sidecar_text, html):
        import yaml
        self.design, self.sidecar_text = design.replace("\r\n", "\n"), sidecar_text
        self.sidecar = json.loads(sidecar_text)
        css = style(html)
        self.rules = rules_of(css)
        self.uses = {"font-size": {}, "border-radius": {}}  # property -> value -> [selectors]
        for sel, body in self.rules:
            if sel.startswith("@"):
                continue
            for raw in re.findall(r"(?<![\w-])font-size\s*:\s*([^;}]+)", body):
                self._use("font-size", raw, sel)
            for raw in re.findall(r"(?<![\w-])font\s*:\s*([^;}]+)", body):
                for tok in raw.split():
                    m = re.match(r"^(\d*\.?\d+(?:px|rem|em))(?:/.*)?$", tok)
                    if m:
                        self._use("font-size", m.group(1), sel); break
            for raw in re.findall(r"(?<![\w-])border-radius\s*:\s*([^;}]+)", body):
                for tok in re.split(r"[\s/]+", raw.strip()):
                    self._use("border-radius", tok, sel)
        m = re.match(r"---\n(.*?)\n---\n", self.design, flags=re.S)
        front = yaml.safe_load(m.group(1)) if m else {}
        front = front if isinstance(front, dict) else {}
        self.colors, self.typo, self.rounded = front.get("colors") or {}, front.get("typography") or {}, front.get("rounded") or {}
        self.ramp = {n for n in (norm(str(t.get("fontSize", ""))) for t in self.typo.values() if isinstance(t, dict)) if n}
        self.scale = {n for n in (norm(str(v)) for v in self.rounded.values()) if n}
        self.theme_ids = sorted(set(re.findall(r'\[data-theme="([a-z]+)"\]\s*\{', css)))

    def _use(self, prop, raw, sel):
        v = norm(raw)
        if v and sel not in self.uses[prop].setdefault(v, []):
            self.uses[prop][v].append(sel)

    def section(self, title, level=2):
        s = re.search(r"^#{%d}[ \t]*%s[ \t]*\n(.*?)(?=^#{1,%d}[ \t]|\Z)" % (level, re.escape(title), level), self.design, flags=re.S | re.M)
        return s.group(1) if s else ""

    def themes_section(self):
        sec = re.search(r"^(#+)[ \t]*Themes[ \t]*\n", self.design, flags=re.M)
        return self.section("Themes", len(sec.group(1))) if sec else ""


def doc():
    return Doc(read("DESIGN.md"), read(".impeccable", "design.json"), read("scripts", "dashboard.html"))


def type_problems(d):
    """AC-7: IBM Plex Sans and Mono (embedded, no Barlow), nothing under 12px, running text capped at 64ch, a 34px to 12px scale"""
    bad = []
    fams = " | ".join(str(t.get("fontFamily", "")) for t in d.typo.values() if isinstance(t, dict))
    if "IBM Plex Sans" not in fams:
        bad.append("no typography fontFamily names IBM Plex Sans")
    if not ("IBM Plex Mono" in fams and "ui-monospace" in fams):
        bad.append("no typography fontFamily is IBM Plex Mono with the ui-monospace fallback")
    if "Barlow" in d.design or "Barlow" in d.sidecar_text:
        bad.append("Barlow is still named in " + ", ".join(n for n, t in (("DESIGN.md", d.design), (".impeccable/design.json", d.sidecar_text)) if "Barlow" in t))
    if not re.search(r"embedded[^\n]*Plex|Plex[^\n]*embedded", d.design, flags=re.I):
        bad.append("DESIGN.md never says the IBM Plex faces are embedded in the file")
    ty = d.section("Typography")
    if not re.search(r"nothing\s+(?:is\s+)?(?:set\s+)?under\s+12px", ty, flags=re.I):
        bad.append("the Typography section never says nothing is under 12px")
    if "64ch" not in ty:
        bad.append("the Typography section never names the 64ch measure")
    sizes = sorted({float(n[:-2]) for n in (norm(str(t.get("fontSize", ""))) for t in d.typo.values() if isinstance(t, dict)) if n and n.endswith("px")})
    if not (sizes and sizes[-1] == 34 and sizes[0] == 12 and set(sizes) <= {34, 24, 17, 16, 15, 14, 13, 12}):
        bad.append("the front matter sizes are %s, want only 34, 24, 17, 16, 15, 14, 13, 12 with both 34 and 12 present" % sizes)
    if [p for p in re.findall(r"font-size\s*:\s*(\d*\.?\d+)px", d.sidecar_text) if float(p) < 12]:
        bad.append("the sidecar has a font-size under 12px")
    return bad


def uppercase_problems(d):
    """AC-7: no line of DESIGN.md asks for uppercase except to forbid it or list an exception, nor keeps type condensed or tracked"""
    lines = d.design.splitlines()
    bad = [l.strip()[:70] for l in lines if re.search(r"uppercase", l, flags=re.I) and not NEG.search(l)]
    bad += ["condensed or tracked uppercase: " + l.strip()[:70] for l in lines
            if re.search(r"condensed|tracked\s+(?:wide|captions)|uppercase\s+(?:and\s+)?tracked|uppercase captions", l, flags=re.I) and not NEG.search(l)]
    return bad


def system_problems(d):
    """AC-7: Colors, Themes, Do's and Don'ts and the front matter say the v4 system"""
    bad = []
    sents = re.split(r"(?<=[.!?])\s+|\n", d.section("Colors"))
    if not any(re.search(r"accent|`sand`", s) and re.search(r"\bonly\b", s) and re.search(r"wait", s) and re.search(r"\bowner\b", s) for s in sents):
        bad.append("no sentence of Colors says the accent marks only what waits for the owner")
    if not any(re.search(r"\bcosts?\b", s) and "`text`" in s and re.search(r"`est`|\best\b", s) for s in sents):
        bad.append("no sentence of Colors says costs are in `text` with `est`")
    if any(re.search(r"\b(?:money|cost)", s, flags=re.I) and re.search(r"accent|`sand`", s) and not NEG.search(s) and "`text`" not in s for s in sents):
        bad.append("Colors still ties the accent to money or costs")
    ts = d.themes_section()
    miss = [n for n in ("Graphite", "Paper", "Cobalt") if not re.search(r"\b%s\b" % n, ts)]
    if miss:
        bad.append("the Themes section misses %s" % miss)
    if not (re.search(r"Auto[^\n]*Graphite[^\n]*dark[^\n]*Paper[^\n]*light|Auto[^\n]*dark[^\n]*Graphite[^\n]*light[^\n]*Paper", ts) and "Kraft in light" not in ts):
        bad.append("the Themes section does not say Auto follows the system with Graphite in dark and Paper in light")
    miss = [k for k in ("raise", "accent-ink", "paper", "accent-soft", "accent-line") if "`%s`" % k not in ts]
    if miss:
        bad.append("the Themes token list misses %s" % miss)
    dd = d.section("Do's and Don'ts").splitlines()
    if not any(re.search(r"uppercase", l, flags=re.I) and re.search(r"\*\*Don't\*\*|\b(?:no|never|not)\b", l) for l in dd):
        bad.append("no Don't line forbids uppercase")
    if not any(re.search(r"accent", l) and re.search(r"wait", l) and re.search(r"\bowner\b", l) for l in dd):
        bad.append("no Do or Don't line ties the accent to what waits for the owner")
    if re.search(r"keep captions uppercase|headings condensed", "\n".join(dd)):
        bad.append("the Do's still keep captions uppercase")
    miss = [k for k in ("raise", "accent-ink", "paper") if k not in d.colors]
    if miss:
        bad.append("colors misses %s" % miss)
    if not (str(d.rounded.get("pill", "")).strip() == "999px" and {"16px", "14px", "8px"} <= d.scale):
        bad.append("rounded is %s, want panel 16px, decision panel 14px, tokens 8px, pill 999px" % d.rounded)
    return bad


def sidecar_problems(d):
    """AC-6: the sidecar is regenerated for v4 (on or after 2026-10-14)"""
    gen = str(d.sidecar.get("generatedAt", ""))[:10]
    return [] if gen >= "2026-10-14" else ["generatedAt is %s" % (gen or "missing")]


def scale_problems(d):
    """AC-2/AC-3 (#120 under v4): the font sizes and radii v4 retires are gone from the page, the ramp has no 28px, the pill is
    999px and 40px leaves the radius scale"""
    bad = []
    for v in ("21px", "22px", "26px", "28px", "30px"):  # 16px and 24px are v4 roles; 28px leaves with the condensed headings
        if d.uses["font-size"].get(v):
            bad.append("font-size %s is still used by %s" % (v, ", ".join(d.uses["font-size"][v][:4])))
    if "28px" in d.ramp:
        bad.append("28px is still a step of the type ramp: %s" % sorted(d.ramp))
    for v in ("1px", "10px"):
        if d.uses["border-radius"].get(v):
            bad.append("border-radius %s is still used by %s" % (v, ", ".join(d.uses["border-radius"][v][:4])))
    if str(d.rounded.get("pill", "")).strip() != "999px":
        bad.append("rounded.pill is %s, want 999px" % d.rounded.get("pill", "missing"))
    if "40px" in d.scale:
        bad.append("40px is still a step of the radius scale: %s" % sorted(d.scale))
    return bad


def deviation_problems(d):
    """AC-6: Known deviations lists none of the values v4 resolved"""
    dev = re.search(r"^## Known deviations[ \t]*\n(.*?)(?=^## |\Z)", d.design, flags=re.S | re.M)
    items = re.findall(r"`([^`]+)`\s*[—–-]+\s*`([^`]+)`", dev.group(1) if dev else "")
    gone = {"21px", "22px", "26px", "28px", "30px", "1px", "10px", "40px"}
    return ["still listed: " + v for v, _ in items if norm(v) in gone]


def in_progress_problems(d):
    """AC-7: the In Progress paragraph says the accent is for a tile that waits for the owner and the cost is in `text` with `est`"""
    prog = d.section("In Progress", 3)
    miss = [w for w, ok in (("a section \"In Progress\"", bool(prog)),
                            ("the accent only on a tile that waits for the owner", re.search(r"accent[^.]*\bowner\b|\bowner\b[^.]*accent", prog) is not None),
                            ("the cost in `text` with `est`", re.search(r"cost[^.]*`text`|`text`[^.]*cost", prog) is not None and re.search(r"`est`|\best\b", prog) is not None)) if not ok]
    return ["the In Progress section does not mention " + ", ".join(miss)] if miss else []


def caption_doc_problems(d):
    """AC-8: Caption is 12px, 400, no tracking, sentence case; Meta is 13px; the sidecar's caption is 12px, plain"""
    bad = []
    cap = d.typo.get("caption") if isinstance(d.typo.get("caption"), dict) else {}
    if not (norm(str(cap.get("fontSize", ""))) == "12px" and str(cap.get("fontWeight", "")) == "400"
            and str(cap.get("letterSpacing", "0")).strip() in ("", "0", "0em", "0px", "normal", "None")):
        bad.append("typography.caption is %s / %s / %s, want 12px / 400 / no tracking" % (cap.get("fontSize", "missing"), cap.get("fontWeight", "missing"), cap.get("letterSpacing", "none")))
    cline = next((l for l in d.design.splitlines() if re.match(r"\s*-\s*\*\*Caption\*\*", l)), "")
    if not ("12px" in cline and "400" in cline and "0.1em" not in cline and "0.14em" not in cline and "11px" not in cline):
        bad.append("the Caption line of Hierarchy is: %s" % (cline or "missing"))
    if "Meta (13px)" not in d.design or re.search(r"Meta\*\* and \*\*note", d.design):
        bad.append("Hierarchy does not read \"Meta (13px)\" or still has \"Meta and note\"")
    dscap = next((c.get("css", "") for c in (d.sidecar.get("components") or []) if isinstance(c, dict) and ".ds-cap{" in str(c.get("css", ""))), "")
    if not dscap:
        m = re.search(r"\.ds-cap\{[^}]*\}", d.sidecar_text)
        dscap = m.group(0) if m else ""
    if dscap and not ("12px" in dscap and ".1em" not in dscap and ".14em" not in dscap and "uppercase" not in dscap and "11px" not in dscap):
        bad.append("the sidecar's .ds-cap is: %s" % dscap[:120])
    return bad


def belt_doc_problems(d):
    """#181 AC-8: The Belt replaces the Lifecycle Band and the Line Peek, and is recorded as the third continuous motion, allowed
    because it carries state and stops under reduced motion"""
    bad = []
    design = d.design
    heads = re.findall(r"^#{2,3}[ \t]*(.+?)[ \t]*$", design, flags=re.M)
    if "Lifecycle Band" in heads:
        bad.append("DESIGN.md still has a Lifecycle Band heading")
    if "Line Peek" in heads:
        bad.append("DESIGN.md still has a Line Peek heading")
    if "The Belt" not in heads:
        bad.append("no heading 'The Belt'; headings: %s" % heads[:30])
    m = re.search(r"[^\n]*(?:lifecycle band|line peek)[^\n]*", design, flags=re.I)
    if m:
        bad.append("DESIGN.md still says: %s" % m.group(0)[:100])
    return bad


def belt_section_problems(d):
    """#181 AC-8: The Belt describes the tokens, the rail and the status sentence, and says it stops under reduced motion"""
    bad = []
    belt = d.section("The Belt", 2) or d.section("The Belt", 3)
    if not all(re.search(w, belt, flags=re.I) for w in ("token", "rail", "status")):
        bad.append("The Belt section does not describe the tokens, the rail and the status sentence: %s" % belt[:120].replace("\n", " "))
    if not re.search(r"reduced motion|prefers-reduced-motion", belt, flags=re.I):
        bad.append("The Belt never mentions reduced motion")
    return bad


def third_motion_problems(d):
    """#181 AC-8: the belt is the third continuous motion, allowed because it carries state and stops under reduced motion"""
    bad = []
    design = d.design
    third = [s for s in re.split(r"(?<=[.!?])\s+|\n", design) if re.search(r"third continuous motion", s, flags=re.I)]
    if not any(re.search(r"\bbelt\b", s, flags=re.I) for s in third):
        bad.append("no sentence calls the belt the third continuous motion")
    if not (any(re.search(r"\bstate\b", s) and re.search(r"reduced", s) for s in third)
            or (bool(third) and re.search(r"carr(?:ies|y)[^.]*state", design)
                and re.search(r"stopped under reduced motion|stops under reduced motion", design))):
        bad.append("the third-motion sentence names neither its state nor reduced motion")
    if re.search(r"two continuous motions", design, flags=re.I):
        bad.append("DESIGN.md still says two continuous motions")
    if re.search(r"third continuous animation", design, flags=re.I):
        bad.append("a Don't still forbids 'a third continuous animation'")
    if not any(re.search(r"\bdial\b", l) and re.search(r"pulse", l) and re.search(r"\bbelt\b", l) and re.search(r"continuous", l)
               for l in design.splitlines()):
        bad.append("no line names the dial, the dot's pulse and the belt as the continuous motion")
    return bad


class V4(support.Case):
    def assert_no_problems(self, problems):
        self.assertEqual(problems, [])

    def test_belt_replaces_band_and_peek(self):
        "AC-8 (#181): DESIGN.md has a section The Belt in place of the Lifecycle Band and the Line Peek"
        self.assert_no_problems(belt_doc_problems(doc()))

    def test_belt_section(self):
        "AC-8 (#181): The Belt describes the tokens, the rail and the status sentence, and stops under reduced motion"
        self.assert_no_problems(belt_section_problems(doc()))

    def test_belt_third_motion(self):
        "AC-8 (#181): the belt is the third continuous motion, allowed because it carries state and stops under reduced motion"
        self.assert_no_problems(third_motion_problems(doc()))

    def test_theme_groups(self):
        "AC-2 (#180): Settings offers Auto, Graphite, Paper and High contrast first, keeps the other eleven, Auto follows the system"
        self.assertEqual(theme_group_problems(page()), [])

    def test_caption_rules(self):
        "AC-6: the Caption rules are 12px with no wide tracking"
        self.assertEqual(caption_problems(page()), [])

    def test_dirty_stepper(self):
        "AC-7: a dirty stepper value is --text"
        self.assertEqual(dirty_stepper_problems(page()), [])

    def test_type(self):
        "AC-7: DESIGN.md and its sidecar say IBM Plex, nothing under 12px, 64ch, a 34px to 12px scale"
        self.assertEqual(type_problems(doc()), [])

    def test_uppercase(self):
        "AC-7: no line of DESIGN.md keeps captions or headings uppercase, condensed or tracked"
        self.assertEqual(uppercase_problems(doc()), [])

    def test_system(self):
        "AC-7: Colors, Themes, Do's and Don'ts and the front matter say the v4 system"
        self.assertEqual(system_problems(doc()), [])

    def test_sidecar_date(self):
        "AC-6: the sidecar was generated on or after 2026-10-14"
        self.assertEqual(sidecar_problems(doc()), [])

    def test_scale(self):
        "AC-2/AC-3: the retired font sizes and radii are gone from the page, no 28px step, the pill is 999px"
        self.assertEqual(scale_problems(doc()), [])

    def test_deviations(self):
        "AC-6: Known deviations lists none of the values v4 resolved"
        self.assertEqual(deviation_problems(doc()), [])

    def test_in_progress(self):
        "AC-7: the In Progress paragraph keeps the accent for the owner and the cost in text with est"
        self.assertEqual(in_progress_problems(doc()), [])

    def test_caption_doc(self):
        "AC-8: DESIGN.md and the sidecar give Caption as 12px, 400, no tracking and Meta as 13px"
        self.assertEqual(caption_doc_problems(doc()), [])

    def test_the_checks_bite(self):
        "on a copy with a v4 rule broken, the checks fail and name it"
        h = page()
        self.assertTrue(dirty_stepper_problems(h.replace(".stp.dirty output { color: var(--text)", ".stp.dirty output { color: var(--sand)")))
        self.assertTrue(caption_problems(h.replace(".cap {", ".cap { letter-spacing: .14em;", 1)))
        self.assertTrue(theme_group_problems(h.replace('"graphite", "paper"', '"paper", "graphite"', 1)))
        d = doc()
        d.design = d.design.replace("Meta (13px)", "Meta (12px)")
        self.assertTrue(caption_doc_problems(d))
        d.design += "\nCaptions are uppercase and tracked.\n"
        self.assertTrue(uppercase_problems(d))
