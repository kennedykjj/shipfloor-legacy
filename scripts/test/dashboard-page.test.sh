#!/usr/bin/env bash
# Dashboard small fixes from the critique (#55): the page source and the pt-BR catalog carry each acceptance criterion.
# Read as text, as theme.test.sh does: no browser, no server. One named check per criterion.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0] + "/test"); import page_text  # the page's text is a catalog by key (#122)
h = page_text.english(h)
cat = json.load(open(sys.argv[2], encoding="utf-8"))
exact, rx = page_text.exact("pt-BR"), {a: b for a, b in cat.get("rx", [])}

def func(name):  # the text of a top-level function of the page script
    m = re.search(r"^(?:async )?function " + name + r"\(", h, re.M)
    if not m: return ""
    rest = h[m.start():]
    end = re.search(r"\n(?:async function |function |const |let |document\.)", rest[10:])
    return rest[: end.start() + 10] if end else rest

def rule(sel):  # the body of the CSS rule(s) whose selector list holds exactly `sel`
    bodies = []
    for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", h):
        if sel in [x.strip() for x in s.split(",")]: bodies.append(b)
    return " ".join(bodies)

def px(body):
    m = re.search(r"font-size:\s*([\d.]+)px", body) or re.search(r"font:[^;]*?\b([\d.]+)px", body)
    return float(m.group(1)) if m else None

def tr(key, want, via=None):
    got = (rx if via == "rx" else exact).get(key)
    return None if got == want else f'catalog {"rx" if via == "rx" else "exact"} "{key}" -> "{want}" (has {got!r})'

res = {}
def check(ac, *problems):
    bad = [p for p in problems if p]
    res[ac] = bad

# AC-1
flags, rsm = func("renderFlags"), func("resume")
check("AC-1",
  None if re.search(r"data-resume", flags) and "btn ghost" in flags else "renderFlags() writes no <button class=\"btn ghost\" data-resume> in the paused alerts",
  None if "Resume the factory" in flags else 'no aria-label "Resume the factory" on the factory alert',
  None if re.search(r"Resume \$\{", flags) else 'no aria-label "Resume <slug>" on the project alert',
  None if "shipfloor resume" not in flags else "the CLI hint `shipfloor resume` is still in the alert text",
  None if "No new run starts. Running sessions finish." in flags and "No new run starts there. Running sessions finish." in flags else "the new alert sentences are missing",
  None if "[data-resume]" in h or re.search(r"dataset\.resume|closest\([^)]*data-resume", h) else "the click handler does not route [data-resume]",
  None if rsm and "/api/settings/pause" in rsm and re.search(r"paused:\s*false", rsm) and "loadOverview" in rsm else "no resume(target) that posts paused: false to /api/settings/pause and reads the overview again",
  None if "S.resuming" in h else "S.resuming (the target in flight) does not exist",
  None if "S.resumeErr" in h else "S.resumeErr does not exist",
  None if "Still paused: the resume did not go through." in h else "the error sentence 'Still paused: the resume did not go through.' is missing",
  None if '[data-view][aria-pressed="true"]' in rsm else "focus does not move to the pressed header view button after a resume",
  tr("No new run starts. Running sessions finish.", "Nenhuma execução nova começa. As sessões que já rodam terminam."),
  tr("No new run starts there. Running sessions finish.", "Nenhuma execução nova começa nele. As sessões que já rodam terminam."),
  tr("Resume", "Retomar"), tr("Resume the factory", "Retomar a fábrica"),
  tr("Still paused: the resume did not go through.", "Continua pausado: a retomada não foi aplicada."),
  None if page_text.msg("pt-BR", "alert.project_paused.resume") == "Retomar {project}" else "pt-BR alert.project_paused.resume is not Retomar {project}")

# AC-2 / AC-3
drawer = func("renderDrawer")
kd = h[h.index('document.addEventListener("keydown", (e) => {\n  const typing'):]
kd = kd[: kd.index("\n});")]
tabb = kd[kd.find('"Tab"'):] if '"Tab"' in kd else ""
static = re.search(r'<aside[^>]*id="drawer"[^>]*>', h).group(0)
guard = re.search(r"S\.open\s*&&\s*S\.full", tabb) or re.search(r"S\.open\s*&&\s*S\.full[^\n]*\n?[^\n]*\"Tab\"", kd) or re.search(r"S\.open\s*&&\s*S\.full[\s\S]{0,200}Tab|Tab[\s\S]{0,200}S\.open\s*&&\s*S\.full", kd)
am = re.search(r"aria-modal[^\n]*", drawer)
check("AC-2",
  None if am and re.search(r"S\.open\s*&&\s*S\.full", am.group(0)) else "renderDrawer() does not set aria-modal from S.open && S.full (maximized drawer must report aria-modal=\"true\")",
  None if "Tab" in kd and guard else "the document keydown listener has no Tab branch guarded by S.open && S.full",
  None if "Tab" in kd and "shiftKey" in kd and "drawer" in kd and "querySelectorAll" in kd else "the Tab branch does not wrap the first and last focusable of #drawer (Shift+Tab and Tab)")
check("AC-3",
  None if am and re.search(r"String\(\s*!!\s*\(\s*S\.open\s*&&\s*S\.full\s*\)\s*\)|\(\s*S\.open\s*&&\s*S\.full\s*\)\s*\?\s*\"true\"\s*:\s*\"false\"", am.group(0)) else "aria-modal does not follow the maximize state live (String(!!(S.open && S.full)) in renderDrawer)",
  None if 'aria-modal="false"' in static else 'the static #drawer markup lost aria-modal="false"',
  None if guard else "the Tab trap is not limited to the maximized drawer: the side drawer must leave to the board")

# AC-4: since #52 a 403 is answered by refuse(), which writes the message. Amended with the owner's approval (2026-10-12):
# the check reads that function, where it read the line that tested the status.
rf = func("refuse")
role = re.search(r"""setAttribute\(\s*["']role["']\s*,\s*["']alert["']\s*\)|\.role\s*=\s*["']alert["']""", rf)
check("AC-4",
  None if role and 0 <= role.start() < rf.find("setHTML(m") else 'refuse() does not set role="alert" on #msg before writing its text',
  None if 'id="msg"' in h and not re.search(r'<p[^>]*id="msg"[^>]*role=|<p[^>]*role=[^>]*id="msg"', h) else 'the static #msg paragraph must stay without role',
  None if re.search(r"""removeAttribute\(\s*["']role["']\s*\)""", h) else 'no other writer of #msg removes the role="alert"')

# AC-5
foot = re.search(r'<p class="foot cap">[\s\S]*?</p>', h)
foot = foot.group(0) if foot else ""
tokens = {t for c in re.findall(r'class="([^"]*)"', foot[len('<p class="foot cap">'):]) for t in c.split()}
dn = [b for s, b in re.findall(r"([^{}]+)\{([^{}]*)\}", h) if ".yours.maxed .foot" in [x.strip() for x in s.split(",")] and "display" in b and "none" in b]
check("AC-5",
  None if all(f"<kbd>{k}</kbd>" in foot for k in "NARL") else "the legend lost N A R L",
  None if '<kbd>1–9</kbd><span data-i="keys.choose">choose</span>' in foot and '<kbd>Esc</kbd><span data-i="keys.close">close</span>' in foot else "the legend does not name <kbd>1–9</kbd>choose and <kbd>Esc</kbd>close",
  None if len(tokens) >= 2 and all(re.search(r"\." + re.escape(t) + r"\b", re.sub(r"<[^>]*>", "", h[: h.index("</style>")])) for t in tokens) else "the legend does not hold two styled groups (list keys, inbox keys) that CSS shows one at a time",
  None if not dn else ".yours.maxed .foot is still in a display: none rule: the legend is hidden in the inbox",
  None if re.search(r"\.yours\.maxed[^{}]*\{[^}]*display", h[: h.index("</style>")]) else "no CSS rule shows one group by .yours.maxed",
  tr("choose", "escolher"), tr("close", "fechar"))

# AC-6
check("AC-6",
  None if (px(rule(".foot")) or 0) >= 12 else f".foot text is {px(rule('.foot'))}px, want at least 12px",
  None if (px(rule(".iopt kbd")) or 0) >= 12 else f".iopt kbd is {px(rule('.iopt kbd'))}px, want at least 12px",
  None if (px(rule(".foot kbd")) or 12) >= 12 else ".foot kbd is smaller than 12px")

# AC-7
feed = func("renderFeed")
fday = rule(".fday")
rawm = re.search(r'const RAW = "[^"]*"', h)
headm = re.search(r'head\s*=\s*d === day \? "" : `([^`]*)`', feed)
check("AC-7",
  None if headm and 'class="fday' in headm.group(1) else 'renderFeed() emits no day row (class "fday") when the calendar day changes',
  None if headm and "DAY_LONG.format" in headm.group(1) and re.search(r"DAY_LONG = new Intl\.DateTimeFormat\(CODE, \{ weekday: \"long\", day: \"numeric\", month: \"long\" \}\)", h) else "the day row does not name the day (weekday, day, month)",
  None if re.search(r"\$\{head\}<li class=\"fev", feed) else "the day row is not placed before the event row (${head} ahead of <li class=\"fev\")",
  None if headm and "fev" not in headm.group(1) else "the day row sits inside an event row",
  None if fday and "var(--hair)" in rule(".fday::after") else ".fday has no CSS (day row with a hairline)",
  None if not rawm or ".fday" not in rawm.group(0) else "the day row is under the RAW selector")

# AC-8
lane = rule(".lane")
check("AC-8",
  None if "color: var(--soft)" in lane.replace("  ", " ") and "var(--sand)" not in lane else f".lane color is not var(--soft) (rule: {lane.strip()})",
  None if "color: var(--muted)" in rule(".lane small") else ".lane small is no longer --muted")

sys.stdout.reconfigure(encoding="ascii", errors="backslashreplace")  # the red/green output stays plain text
for ac in sorted(res):
    print(ac + ": " + ("ok" if not res[ac] else "FAIL " + "; ".join(res[ac])))
PY
)"
for n in 1 2 3 4 5 6 7 8; do
  line="$(printf '%s\n' "$out" | grep -a "^AC-$n:")"
  case "$line" in
    "AC-$n: ok") pass "AC-$n" ;;
    "") fail "AC-$n: the check did not run: $out" ;;
    *) fail "$line" ;;
  esac
done
finish
