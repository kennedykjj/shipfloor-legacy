#!/usr/bin/env bash
# Dashboard Feed (#114): runs are the default view, a failed run says why (the gate, or the exit code) and never "ok",
# and dates follow the dashboard's language. No browser: the API half starts dashboard.py on a temp home and reads
# /api/feed; the page half reads dashboard.html and the pt-BR catalog as text. A test never touches the real
# ~/.shipfloor, nor the real scheduled task.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; BASH_N="$(nat "$(command -v bash)")"
P="$H/projects/shop"; D="$(date +%F)"
mkdir -p "$H/logs" "$P/logs" "$P/locks" "$P/reports-wt/reports/21-gate" "$P/reports-wt/reports/23-ok" "$C/claude"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
printf '21\tValidation\n22\tValidation\n23\tStaged\n' > "$P/board.tsv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$C/sched-stub.sh"

# the dispatcher's and the stacks' lines (one repeated in a row), and three runs:
# 21 failed on a gate its report names, 22 failed with no report (its last log line reads like a success), 23 ended well
printf '%sT10:00:00-03:00 shipfloor: shop: first\n%sT10:20:00-03:00 shipfloor: shop: again\n%sT10:23:00-03:00 shipfloor: shop: again\n' "$D" "$D" "$D" > "$H/logs/dispatcher.log"
printf '%sT10:30:00-03:00 stacks: stack 1 is free\n' "$D" > "$H/logs/stacks.log"
printf '== start /sf:develop 21 %sT10:05:00-03:00 pid=1\ngate build: 2 tests failed\n== end /sf:develop 21 exit=4 %sT10:06:00-03:00\n' "$D" "$D" > "$P/logs/$D-21-develop.log"
printf '{"outcome":"failed","pr":64,"failed_gates":["build","lint"]}\n' > "$P/reports-wt/reports/21-gate/develop-${D}T100530.json"
printf '== start /sf:develop 22 %sT10:10:00-03:00 pid=2\nok · now in Validation\n== end /sf:develop 22 exit=3 %sT10:11:00-03:00\n' "$D" "$D" > "$P/logs/$D-22-develop.log"
printf '== start /sf:develop 23 %sT10:15:00-03:00 pid=3\nall gates passed\n== end /sf:develop 23 exit=0 %sT10:16:00-03:00\n' "$D" "$D" > "$P/logs/$D-23-develop.log"
printf '{"outcome":"done","pr":65}\n' > "$P/reports-wt/reports/23-ok/develop-${D}T101530.json"

SHIPFLOOR_SCHEDULER="\"$BASH_N\" \"$(nat "$C")/sched-stub.sh\"" SHIPFLOOR_BASH="$BASH_N" FAKE_GH_NO_JQ=1 FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_DIR="$C" CLAUDE_CONFIG_DIR="$(nat "$C/claude")" \
  $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$C/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$C/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$C/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
curl -s -H "X-Shipfloor-Token: $tok" "$base/api/feed" > "$C/feed.json"
[ -s "$C/feed.json" ] && pass "the feed is served" || fail "the feed came back empty: $(cat "$C/out")"

out="$($PY -I -X utf8 - "$(nat "$C/feed.json")" "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" <<'PY'
import json, re, sys
ev = json.load(open(sys.argv[1], encoding="utf-8"))["events"]
h = open(sys.argv[2], encoding="utf-8").read()
cat = json.load(open(sys.argv[3], encoding="utf-8"))
exact, rx = cat.get("exact", {}), [tuple(x) for x in cat.get("rx", [])]
res = []

def chk(ok, good, bad):
    res.append(("ok " if ok else "FAIL ") + (good if ok else bad))

def block(name):  # the text of a top-level function or const of the page script
    m = re.search(r"^(?:async )?(?:function |const |let )" + name + r"\b", h, re.M)
    if not m:
        return ""
    rest = h[m.start():]
    end = re.search(r"\n(?:async function |function |const |let |document\.)", rest[10:])
    return rest[: end.start() + 10] if end else rest

def run(n):
    return next((e for e in ev if e.get("issue") == n), {})

sysev = [e for e in ev if not e.get("issue")]
gate, noreport, good = run(21), run(22), run(23)
isline = (re.search(r"^const FEED_IS = .*$", h, re.M) or [""])[0]
names = (re.search(r"^const FEED_NAMES = .*$", h, re.M) or [""])[0]
keys = re.findall(r"(\w+):\s*\(", isline)
rf, left, when, hhmm, dl = block("renderFeed"), block("feedLeft"), block("when"), block("hhmm"), block("dateLocale")
undef = r"toLocale\w*\(\s*(undefined|\))"

# ---- AC-1: only run lines show when the Feed opens
chk(len(sysev) >= 3 and all(run(n) for n in (21, 22, 23)), "AC-1 the feed holds run lines and dispatcher/stacks lines",
    "AC-1 setup: the feed has %d dispatcher lines and runs %s" % (len(sysev), [e.get("issue") for e in ev if e.get("issue")]))
chk(re.search(r'S\.feedFilter \|\| "runs"', rf) is not None, "AC-1 the Feed opens on the Runs filter",
    "AC-1 the default feed filter is %r and not Runs, so dispatcher lines show when the Feed opens" % (re.search(r'S\.feedFilter \|\| "(\w+)"', rf) or [0, "?"])[1])
chk(re.search(r"\bruns:\s*\(e\)\s*=>\s*e\.issue\s*[,}]", isline) is not None, "AC-1 Runs is every run line and no dispatcher line (e.issue)",
    "AC-1 FEED_IS has no `runs` filter that keeps run lines only (e.issue); keys are %s" % keys)
chk('runs: "Runs"' in names and '"All"' not in names, "AC-1 the filter is named Runs and no All is left",
    "AC-1 FEED_NAMES does not name the filter `Runs` or still names `All`: %s" % names.strip())
chk(exact.get("Runs") == "Execuções", "AC-1 pt-BR names the filter Execuções",
    "AC-1 the pt-BR catalog has no exact entry Runs -> Execuções (has %r)" % exact.get("Runs"))

# ---- AC-2: the Dispatcher filter is unchanged, and no All beside Runs
chk(keys == ["runs", "you", "bad", "run", "sys"], "AC-2 the filter row is Runs, Waits for you, Failures, Running, Dispatcher",
    "AC-2 the filter row is %s: `all` is still there and Runs does not come first (want runs, you, bad, run, sys)" % keys)
chk(re.search(r"\bsys:\s*\(e\)\s*=>\s*!e\.issue\b", isline) is not None and 'sys: "Dispatcher"' in names, "AC-2 Dispatcher keeps the dispatcher and stacks lines (!e.issue)",
    "AC-2 the Dispatcher filter changed: FEED_IS/FEED_NAMES no longer read sys: !e.issue / Dispatcher")
chk('class="fev f-sys"' in rf and "<span>since</span>" in rf and "e.n > 1" in rf, "AC-2 dispatcher rows keep f-sys, the dash mark and the N× since count",
    "AC-2 the dispatcher row in renderFeed lost its f-sys class or its `N× since` count")
chk(exact.get("Dispatcher", "Dispatcher") == "Dispatcher", "AC-2 Dispatcher stays Dispatcher in pt-BR",
    "AC-2 the pt-BR catalog translates Dispatcher to %r" % exact.get("Dispatcher"))
texts = {e["text"]: e for e in sysev}
chk(set(texts) == {"shipfloor: shop: first", "shipfloor: shop: again", "stacks: stack 1 is free"}
    and texts.get("shipfloor: shop: again", {}).get("n") == 2 and texts["stacks: stack 1 is free"].get("source") == "stacks"
    and all(set(e) == {"ts", "source", "text", "n", "since"} for e in sysev),
    "AC-2 the API still sends the dispatcher and stacks lines with the same text, count and fields",
    "AC-2 the dispatcher/stacks events changed: %s" % json.dumps(sysev, ensure_ascii=False))

# ---- AC-3: a run that failed on a gate names it on the second line
chk(gate.get("failed") == ["build", "lint"] and gate.get("exit") == 4 and gate.get("pr") == 64, "AC-3 the API gives the failed run its failed gates from the report",
    "AC-3 the failed run's event does not carry failed=[build, lint], pr 64 and exit 4: %s" % gate)
chk("last" not in gate, "AC-3 the failed run's event no longer carries the last log line",
    "AC-3 the failed run's event still carries `last` (%r), the last log line shown under the title" % gate.get("last"))
i_fail, i_pr = left.find("e.failed"), left.find("PR #")
chk(0 <= i_fail < i_pr, "AC-3 feedLeft puts the gate reason before PR #n",
    "AC-3 feedLeft does not open with the failed gates: PR # comes first (e.failed at %d, PR # at %d)" % (i_fail, i_pr))
chk(0 <= i_fail < left.find("now in") and "gates failed" in left and "fraw" in left, "AC-3 the reason reads `gates failed: <names>` with raw gate names, before `now in`",
    "AC-3 feedLeft does not put `gates failed: <names>` (class fraw) before `now in <column>`")
chk(exact.get("gates failed") == "gates que falharam", "AC-3 pt-BR has `gates failed`",
    "AC-3 the pt-BR catalog lost `gates failed`")

# ---- AC-4: no gate on record: the exit code; never "ok", never a success log line
chk(noreport.get("exit") == 3 and "failed" not in noreport and noreport.get("column") == "Validation", "AC-4 the API gives the run with no report its exit code and no failed gates",
    "AC-4 the no-report run's event is not exit 3 with no `failed`: %s" % noreport)
chk("last" not in noreport and "now in Validation" not in json.dumps(noreport), "AC-4 the run's event carries no log line that could read ok",
    "AC-4 the no-gate failed run's event still carries `last`=%r, a success-looking log line under a failed run" % noreport.get("last"))
chk("ended with exit" in left and "e.exit" in left and re.search(r"<span>no failed gate recorded</span>", left) is not None,
    "AC-4 feedLeft says `ended with exit <n>` and `no failed gate recorded` in its own span when no gate is on record",
    "AC-4 feedLeft never says `ended with exit <n> · no failed gate recorded` for a failed run with no gate")
chk(0 <= left.find("ended with exit") < left.find("PR #"), "AC-4 the exit reason comes before PR #n",
    "AC-4 the exit reason is not the start of the second line")
chk(re.search(r"\be\.last\b", h) is None, "AC-4 the page reads no log line (e.last) anywhere",
    "AC-4 the page still reads e.last, the last log line, which can read ok under a failed run")
chk(exact.get("no failed gate recorded") == "nenhum gate que falhou foi registrado", "AC-4 pt-BR: no failed gate recorded",
    "AC-4 the pt-BR catalog has no exact entry `no failed gate recorded` (has %r)" % exact.get("no failed gate recorded"))
pats = [a for a, _ in rx]
chk(dict(rx).get(r"ended with exit (\d+)") == "terminou com exit $1" and r" and ended with exit (\d+)" in pats
    and pats.index(r"ended with exit (\d+)") > pats.index(r" and ended with exit (\d+)") if r"ended with exit (\d+)" in pats else False,
    "AC-4 pt-BR: `ended with exit N` comes after ` and ended with exit N` in the catalog",
    "AC-4 the pt-BR catalog has no rx `ended with exit (\\d+)` -> `terminou com exit $1` placed after ` and ended with exit (\\d+)`")

# ---- AC-5: a run that ended well keeps today's second line
chk(good.get("exit") == 0 and "last" not in good and good.get("pr") == 65 and good.get("column") == "Staged" and "failed" not in good,
    "AC-5 the API gives the good run its PR and column, and no last line (as before)",
    "AC-5 the good run's event changed: %s" % good)
chk(re.search(r"\be\.last\b", left) is None, "AC-5 feedLeft builds the line without e.last",
    "AC-5 feedLeft still builds the second line with e.last")
chk(0 <= left.find("PR #") < left.find("now in") < left.find("Step "), "AC-5 the good run's line is PR #n, then now in <column>, then the step",
    "AC-5 feedLeft lost the order PR #n, now in <column>, step")
chk(exact.get("now in") is not None, "AC-5 pt-BR keeps `now in`", "AC-5 the pt-BR catalog lost `now in`")

# ---- AC-6: English: the day header's weekday and month do not come from the browser
chk("function dateLocale" in dl or dl.startswith("const dateLocale"), "AC-6 the page has one dateLocale() helper",
    "AC-6 the page has no dateLocale() helper that picks the locale from the dashboard's language")
chk("document.documentElement.lang" in dl and '"en-US"' in dl and "navigator" not in dl, "AC-6 dateLocale() reads the page's language and falls back to en-US, never the browser's",
    "AC-6 dateLocale() does not read document.documentElement.lang with an en-US fallback (got %r)" % dl[:120])
chk(re.search(r"toLocaleDateString\(\s*dateLocale\(\)\s*,\s*\{[^}]*weekday:\s*\"long\"[^}]*month:\s*\"long\"", rf) is not None and re.search(undef, rf) is None,
    "AC-6 the day header passes dateLocale() to toLocaleDateString (weekday and month long)",
    "AC-6 the day header (renderFeed) formats with the browser's locale: toLocaleDateString(undefined, ...) instead of dateLocale()")
chk('class="fday cap"' in rf and re.search(r'head = d === day \? "" : `<li class="fday cap">', rf) is not None, "AC-6 the day header keeps its shape (head = d === day ? ...)",
    "AC-6 the day header lost its `head = d === day ? \"\" : <li class=\"fday cap\">` shape")

# ---- AC-7: pt-BR: the same header in Portuguese
chk(re.search(r'documentElement\.lang\s*===?\s*"pt-BR"', dl) is not None and '"pt-BR"' in dl, "AC-7 dateLocale() returns pt-BR when the page is in pt-BR",
    "AC-7 dateLocale() does not return pt-BR for a page in pt-BR, so the day header would not be in Portuguese")
chk(re.search(r"dateLocale\(\)", rf) is not None and "toLocaleDateString(undefined" not in rf, "AC-7 the Feed's day header takes that locale",
    "AC-7 the Feed's day header does not take its locale from dateLocale()")
chk(re.search(r"document\.documentElement\.lang\s*=\s*body\.language", h) is not None, "AC-7 loadLang() sets the page's language the helper reads",
    "AC-7 nothing sets document.documentElement.lang from /api/lang")

# ---- AC-8: when() and hhmm() follow the dashboard's language on the whole page
chk(when != "" and re.search(undef, when) is None and "dateLocale()" in when, "AC-8 when() formats with dateLocale()",
    "AC-8 when() formats with the browser's locale: toLocale*(undefined, ...) instead of dateLocale()")
chk(hhmm != "" and re.search(undef, hhmm) is None and "dateLocale()" in hhmm, "AC-8 hhmm() formats with dateLocale()",
    "AC-8 hhmm() formats with the browser's locale: toLocaleTimeString(undefined, ...) instead of dateLocale()")
chk('hourCycle: "h23"' in when and 'hourCycle: "h23"' in hhmm, "AC-8 both times are 24-hour (hourCycle h23) in both languages",
    "AC-8 when() and hhmm() are not both 24-hour (hourCycle: \"h23\"): an English browser would show AM/PM")
chk(re.search(r'month:\s*"short"', when) is not None and re.search(r'day:\s*"2-digit"\s*,\s*month:\s*"2-digit"', when) is not None
    and "pt-BR" in when, "AC-8 when() on another day: `Oct 12` in English, `12/10` in pt-BR",
    "AC-8 when() on another day does not give a month word in English ({month: short, day: numeric}) and day/month in pt-BR")

print("\n".join(res))
PY
)"
while IFS= read -r l; do
  l="${l%$'\r'}"
  case "$l" in
    "ok "*) pass "${l#ok }" ;;
    "FAIL "*) fail "${l#FAIL }" ;;
    "") ;;
    *) fail "the checker broke: $l" ;;
  esac
done <<< "$out"
finish
