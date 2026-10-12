#!/usr/bin/env bash
# #119 AC-4 to AC-8: the dashboard at a glance. A docs link in the header, each figure once, durations past two days
# in days and hours, and the pt-BR catalog following. The page and the catalog are read as text; no browser.
source "$(dirname "$0")/lib.sh"
out="$("$FACTORY_PYTHON" -I - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, shutil, subprocess, sys
h = open(sys.argv[1], encoding="utf-8").read()
cat = json.load(open(sys.argv[2], encoding="utf-8"))
res = []
def check(name, cond, why): res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
def src(start):
    i = h.find(start)
    if i < 0: return ""
    eol = h.find("\n", i)
    if start.startswith("function") and eol > 0 and h[i:eol].rstrip().endswith("}"): return h[i:eol]
    j = h.find("\n}", i)
    return h[i:j + 2] if j > 0 else h[i:]

DOCS = "https://github.com/kennedykjj/shipfloor#learn-more"
header = h[h.find("<header>"):h.find("</header>")]
stats = re.search(r'<div class="stats">\s*(<a\b[^>]*>)(.*?)</a>\s*<span id="scope">', header, re.S)
tag, label = (stats.group(1), stats.group(2)) if stats else ("", "")

# AC-4: one link, in the header, the same on every view, in a new tab
check("AC-4 the docs link is the first child of .stats, before #scope", bool(stats), 'no <a> as first child of div.stats before span#scope in the static <header>')
check("AC-4 it is labelled Docs", label.strip().startswith("Docs"), f"its label is {label.strip()[:30]!r}")
check("AC-4 it is an a.cap like Board on GitHub", bool(re.search(r'class="cap"', tag)), "the link is not a.cap")
check("AC-4 href is the README's learn-more table", f'href="{DOCS}"' in tag, f"href is not {DOCS}")
check("AC-4 it opens in a new tab", 'target="_blank"' in tag, 'no target="_blank"')
check("AC-4 with rel=noopener", 'rel="noopener"' in tag, 'no rel="noopener"')
check("AC-4 the link is written once", h.count("#learn-more") == 1, f"learn-more appears {h.count('#learn-more')} times")
check("AC-4 renderStrip does not write it", "learn-more" not in src("function renderStrip"), "the link is written by renderStrip, not by the static header")

# AC-5: offline, the page is complete; nothing is fetched until the link is clicked
check("AC-5 the page loads no resource from the network", not re.search(r'<(?:script|img|iframe|source)\b[^>]*\b(?:src|srcset)\s*=\s*["\']?(?:https?:)?//', h) and not re.search(r'<link\b[^>]*\bhref\s*=\s*["\']?(?:https?:)?//', h), "a tag loads a network asset")
check("AC-5 no preload, prefetch or preconnect", not re.search(r'<link\b[^>]*\brel\s*=\s*["\']?(?:preload|prefetch|preconnect|dns-prefetch|prerender)', h), "a link hints the browser to reach the network")
check("AC-5 the docs link is not fetched by the page", not re.search(r"(?:fetch|XMLHttpRequest|sendBeacon)\([^)]*(?:github\.com/kennedykjj|learn-more)", h), "the page's script requests the docs")
check("AC-5 the docs link needs no script to exist", bool(stats) and "learn-more" not in "".join(re.findall(r"<script\b.*?</script>", h, re.S)), "the link is built by a script")

# AC-6: pool, runs today and spend once; the summary sentence is gone
check("AC-6 renderSum is gone", "renderSum" not in h, "function renderSum is still in the page")
check("AC-6 no element #sum", 'id="sum"' not in h and "#sum" not in h, "span#sum or its CSS is still in the page")
sl = re.search(r'<div class="sumline"[^>]*>(.*?)</div>', h, re.S)
check("AC-6 #sumline holds only the two fold buttons", bool(sl) and len(re.findall(r"<button\b", sl.group(1))) == 2 and "<span" not in sl.group(1), "#sumline holds more than the Lifecycle and Today buttons")
check("AC-6 the header shows Pool, Runs today and Spent est. once each", h.count("Pool<b>") == 1 and h.count("Runs today<b>") == 1 and h.count("Spent est.<b>") == 1, "a figure of the header is missing or written twice")
check("AC-6 no sentence repeats them", "est. spent today" not in h and "renderSum" not in h, "the page still writes the summary sentence")
rs = src("function renderStrip")
check("AC-6 with several projects the header titles say they are the machine's", "Runs of every project today" in rs and "Every project, today." in rs and "projects.length > 1" in rs, "renderStrip has no 'Runs of every project today' / 'Every project, today.' titles for more than one project")
check("AC-6 spend keeps its est. label", "Spent est." in rs, "Spent est. is gone")

# AC-7: durations past 48 h in days and hours
dur = re.search(r"^function dur\(a, b\).*$", h, re.M)
ds = dur.group(0) if dur else ""
check("AC-7 dur() switches at 172800 s and prints days and hours", "172800" in ds and "86400" in ds and "d " in ds, "dur() has no branch above 172800 s printing <days>d <hours>h")
node = shutil.which("node")
if node and ds:
    cases = [(96 * 3600 + 8 * 60, "4d 0h"), (172801, "2d 0h"), (2 * 86400 + 3600 + 60, "2d 1h"), (12 * 86400 + 23 * 3600 + 3599, "12d 23h"),
             (172800, "48h00"), (47 * 3600 + 59 * 60, "47h59"), (2520, "42m"), (3600, "1h00")]
    js = ds + "\nconst t = (s) => dur(new Date(0).toISOString(), new Date(s * 1000).toISOString());\nconsole.log(JSON.stringify(" + json.dumps([c[0] for c in cases]) + ".map(t)));"
    r = subprocess.run([node, "-e", js], capture_output=True, text=True)
    try: got = json.loads(r.stdout)
    except ValueError: got = [r.stderr.strip()[:80]] * len(cases)
    for (s, want), g in zip(cases, got):
        check(f"AC-7 dur of {s} s reads {want}", g == want, f"it reads {g!r}")

# AC-8: pt-BR
ex, rx = cat["exact"], cat["rx"]
def want(k, v): check(f"AC-8 pt-BR {k!r}", ex.get(k) == v, f"exact entry missing or not {v!r}: {ex.get(k)!r}")
want("Docs", "Documentação")
want("Infrastructure failed; the factory retries once", "A infraestrutura falhou; a fábrica tenta mais uma vez")
want("Runs of every project today", "Execuções de todos os projetos hoje")
want("Every project, today.", "Todos os projetos, hoje.")
check("AC-8 the old infrastructure sentence leaves the catalog", "Blocked by infrastructure; the factory retries it" not in ex, "the old entry is still there")
for k in ("\\bin use\\b", "est\\. spent today", "(\\d+) runs? today"):
    check(f"AC-8 the summary rx {k!r} is removed", not any(a == k for a, b in rx), "the entry is still in the catalog")
def captures(text):
    for a, b in rx:
        m = re.search(a, text)
        if m and "$1" in b and m.group(1): return m.group(1)
    return None
check("AC-8 'Running · last cycle 4d 0h ago' captures the whole duration", captures("Running · last cycle 4d 0h ago") == "4d 0h", f"captured {captures('Running · last cycle 4d 0h ago')!r}")
check("AC-8 'board read 4d 0h ago' captures the whole duration", captures("board read 4d 0h ago") == "4d 0h", f"captured {captures('board read 4d 0h ago')!r}")
check("AC-8 a short duration is still one token", captures("Running · last cycle 5m ago") == "5m" and captures("board read 47h59 ago") == "47h59", "a duration of 48 h or less is not captured whole")
check("AC-8 'd' needs no catalog entry", "d" not in ex and not any(a in ("d", "\\bd\\b") for a, b in rx), "a day-unit entry was added")
m = re.search(r'const RAW = "([^"]*)"', h)
check("AC-8 .pwhy is in the RAW selector, so the factory's words are not translated", bool(m) and ".pwhy" in [s.strip() for s in m.group(1).split(",")], ".pwhy is not in RAW")
# the red gate shows the first 20 failing lines: interleave the ACs so each one's first failure is among them
seen, ranked = {}, []
for r in res:
    ac = re.search(r"AC-\d", r).group(0)
    seen[ac] = seen.get(ac, 0) + 1
    ranked.append((seen[ac], len(ranked), r))
print("\n".join(r for _, _, r in sorted(ranked)))
PY
)"
while IFS= read -r line; do
  case "$line" in "ok "*) pass "${line#ok }" ;; "no "*) fail "${line#no }" ;; *) fail "unexpected: $line" ;; esac
done <<< "$out"
finish
