#!/usr/bin/env bash
# The page at a glance (#119): one link to the docs on every view, the day's figures once, long durations in days.
# Reads scripts/dashboard.html and the pt-BR catalog; dur() runs in node when there is one.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
cat = json.load(open(sys.argv[2], encoding="utf-8"))
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
def fn(name):
    i = h.find(f"function {name}(")
    return "" if i < 0 else h[i:h.find("\n}", i) + 2]
markup = h[h.index("<body>"):h.index("<script", h.index("<body>"))]

# AC-4: one docs link, in the static header, before the project switch, opening in a new tab
stats = re.search(r'<div class="stats">(.*?)</div>', markup, re.S)
first = re.match(r"\s*(<a [^>]*>)(.*?)</a>", stats.group(1), re.S) if stats else None
check("AC-4 the docs link is the first thing in the header's stats", bool(first) and first.group(2).startswith("Docs"), "no <a>Docs</a> first in .stats")
a = first.group(1) if first else ""
check("AC-4 it points at the README's docs table", 'href="https://github.com/kennedykjj/shipfloor#learn-more"' in a, a)
check("AC-4 it opens in a new tab", 'target="_blank"' in a and 'rel="noopener"' in a, a)
check("AC-4 it is written once, in the markup, not by a render", h.count("#learn-more") == 1 and "learn-more" not in fn("renderStrip"), "the link is missing, repeated or rendered")
check("AC-4 the header sits outside every view", markup.find('<div class="stats">') < markup.find("<main>"), "the stats are inside a view")
# AC-5: nothing about it is fetched before a click: no external resource in the page
ext = re.findall(r'<(?:script|link|img|iframe)[^>]+(?:src|href)="https?://[^"]+"', h)
check("AC-5 the page loads no external resource", not ext, f"external resources: {ext}")
check("AC-5 no preload or prefetch", not re.search(r'rel="(?:preload|prefetch|preconnect|dns-prefetch)"', h), "a hint fetches ahead")
# AC-6: pool, runs and spend once above the panels, the spend still an estimate
rs = fn("renderStrip")
for label in (">Pool<", ">Runs today<", ">Spent est.<"):
    check(f"AC-6 the header shows {label.strip('<>')} once", rs.count(label) == 1, f"{rs.count(label)} times in renderStrip")
check("AC-6 no summary sentence", "renderSum" not in h and 'id="sum"' not in h and "est. spent today" not in h, "the sentence is still in the page")
check("AC-6 with several projects the titles say the figures are the machine's", "Runs of every project today" in rs and "Every project, today." in rs and "projects.length > 1" in rs, "renderStrip lacks the machine titles")
# AC-8: the new texts are translated; the factory's line is not
ex = cat["exact"]
check("AC-8 Docs in pt-BR", ex.get("Docs") == "Documentação", ex.get("Docs"))
check("AC-8 the infrastructure line in pt-BR", ex.get("Infrastructure failed; the factory retries once") == "A infraestrutura falhou; a fábrica tenta mais uma vez", "missing")
check("AC-8 the runs title in pt-BR", ex.get("Runs of every project today") == "Execuções de todos os projetos hoje", "missing")
check("AC-8 the spend title in pt-BR", any(a == "^Every project, today\\.\\n" and b == "Todos os projetos, hoje.\n" for a, b in cat["rx"]), "missing")
check("AC-8 the old infrastructure line is gone from the catalog", "Blocked by infrastructure; the factory retries it" not in ex, "still there")
for k in ("Running · last cycle (\\d+d \\d+h|\\S+) ago", "board read (\\d+d \\d+h|\\S+) ago"):
    check(f"AC-8 {k.split(' (')[0]} accepts a duration in days", any(a == k for a, b in cat["rx"]), "the capture does not take '4d 0h'")
check("AC-8 the reason line stays out of the catalog", ".pwhy" in re.search(r"const RAW = \"([^\"]+)\"", h).group(1), ".pwhy is not in RAW")
print("\n".join(res))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"

# AC-7: past 48 h a duration reads in days and hours; up to 48 h as before
if command -v node >/dev/null; then
  durjs="$(grep '^function dur(' "$FACTORY_DIR/dashboard.html")"
  got="$(node -e "$durjs
const at = (s) => dur(new Date(0).toISOString(), new Date(s * 1000).toISOString());
console.log([42 * 60, 47 * 3600 + 59 * 60, 48 * 3600, 48 * 3600 + 60, 96 * 3600 + 8 * 60, 49 * 3600, 12 * 86400 + 23 * 3600 + 59 * 60].map(at).join('|'))")"
  [ "$got" = "42m|47h59|48h00|2d 0h|4d 0h|2d 1h|12d 23h" ] && pass "AC-7 dur: 42m, 47h59, 48h00, then days and hours" || fail "AC-7 dur gave $got"
else
  assert_contains "$(grep '^function dur(' "$FACTORY_DIR/dashboard.html")" 'if (s > 172800) return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`'
fi
finish
