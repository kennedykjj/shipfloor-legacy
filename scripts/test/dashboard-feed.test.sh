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
pt = cat.get("messages", {})  # the page asks for its text by key (#122)
en = json.load(open(sys.argv[3].replace("pt-BR", "en"), encoding="utf-8"))["messages"]
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
names = {k[len("feed.f."):]: v for k, v in en.items() if k.startswith("feed.f.")}
keys = re.findall(r"(\w+):\s*\(", isline)
rf, left, when, hhmm = block("renderFeed"), block("feedLeft"), block("when"), block("hhmm")
undef = r"toLocale\w*\(\s*(undefined|\))"

# ---- AC-1: only run lines show when the Feed opens
chk(len(sysev) >= 3 and all(run(n) for n in (21, 22, 23)), "AC-1 the feed holds run lines and dispatcher/stacks lines",
    "AC-1 setup: the feed has %d dispatcher lines and runs %s" % (len(sysev), [e.get("issue") for e in ev if e.get("issue")]))
chk(re.search(r'S\.feedFilter \|\| "runs"', rf) is not None, "AC-1 the Feed opens on the Runs filter",
    "AC-1 the default feed filter is %r and not Runs, so dispatcher lines show when the Feed opens" % (re.search(r'S\.feedFilter \|\| "(\w+)"', rf) or [0, "?"])[1])
chk(re.search(r"\bruns:\s*\(e\)\s*=>\s*e\.issue\s*[,}]", isline) is not None, "AC-1 Runs is every run line and no dispatcher line (e.issue)",
    "AC-1 FEED_IS has no `runs` filter that keeps run lines only (e.issue); keys are %s" % keys)
chk(names.get("runs") == "Runs" and "All" not in names.values() and 't(`feed.f.${k}`)' in rf, "AC-1 the filter is named Runs and no All is left",
    "AC-1 FEED_NAMES does not name the filter `Runs` or still names `All`: %s" % names)
chk(pt.get("feed.f.runs") == "Execuções", "AC-1 pt-BR names the filter Execuções",
    "AC-1 the pt-BR catalog has no feed.f.runs Execuções (has %r)" % pt.get("feed.f.runs"))

# ---- AC-2: the Dispatcher filter is unchanged, and no All beside Runs
chk(keys == ["runs", "you", "bad", "run", "sys"], "AC-2 the filter row is Runs, Waits for you, Failures, Running, Dispatcher",
    "AC-2 the filter row is %s: `all` is still there and Runs does not come first (want runs, you, bad, run, sys)" % keys)
chk(re.search(r"\bsys:\s*\(e\)\s*=>\s*!e\.issue\b", isline) is not None and names.get("sys") == "Dispatcher", "AC-2 Dispatcher keeps the dispatcher and stacks lines (!e.issue)",
    "AC-2 the Dispatcher filter changed: FEED_IS/FEED_NAMES no longer read sys: !e.issue / Dispatcher")
chk('class="fev f-sys"' in rf and 't("feed.repeat", { n: e.n, since: hhmm(e.since) })' in rf and "e.n > 1" in rf and en.get("feed.repeat") == "{n}× since {since}", "AC-2 dispatcher rows keep f-sys, the dash mark and the N× since count",
    "AC-2 the dispatcher row in renderFeed lost its f-sys class or its `N× since` count")
chk(pt.get("feed.f.sys") == "Dispatcher", "AC-2 Dispatcher stays Dispatcher in pt-BR",
    "AC-2 the pt-BR catalog translates Dispatcher to %r" % pt.get("feed.f.sys"))
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
i_fail, i_pr = left.find("e.failed"), left.find("feed.pr")
chk(0 <= i_fail < i_pr, "AC-3 feedLeft puts the gate reason before PR #n",
    "AC-3 feedLeft does not open with the failed gates: PR # comes first (e.failed at %d, PR # at %d)" % (i_fail, i_pr))
chk(0 <= i_fail < left.find("feed.now_in") and "feed.gates_failed" in left and "fraw" in left and en.get("feed.gates_failed") == "gates failed: {gates}", "AC-3 the reason reads `gates failed: <names>` with raw gate names, before `now in`",
    "AC-3 feedLeft does not put `gates failed: <names>` (class fraw) before `now in <column>`")
chk(pt.get("feed.gates_failed") == "gates que falharam: {gates}", "AC-3 pt-BR has `gates failed`",
    "AC-3 the pt-BR catalog lost `gates failed`")

# ---- AC-4: no gate on record: the exit code; never "ok", never a success log line
chk(noreport.get("exit") == 3 and "failed" not in noreport and noreport.get("column") == "Validation", "AC-4 the API gives the run with no report its exit code and no failed gates",
    "AC-4 the no-report run's event is not exit 3 with no `failed`: %s" % noreport)
chk("last" not in noreport and "now in Validation" not in json.dumps(noreport), "AC-4 the run's event carries no log line that could read ok",
    "AC-4 the no-gate failed run's event still carries `last`=%r, a success-looking log line under a failed run" % noreport.get("last"))
chk('`${t("feed.exit", { n: e.exit })} · ${t("feed.no_gate")}`' in left and en.get("feed.exit") == "ended with exit {n}" and en.get("feed.no_gate") == "no failed gate recorded",
    "AC-4 feedLeft says `ended with exit <n>` and `no failed gate recorded` in its own span when no gate is on record",
    "AC-4 feedLeft never says `ended with exit <n> · no failed gate recorded` for a failed run with no gate")
chk(0 <= left.find("feed.exit") < left.find("feed.pr"), "AC-4 the exit reason comes before PR #n",
    "AC-4 the exit reason is not the start of the second line")
chk(re.search(r"\be\.last\b", h) is None, "AC-4 the page reads no log line (e.last) anywhere",
    "AC-4 the page still reads e.last, the last log line, which can read ok under a failed run")
chk(pt.get("feed.no_gate") == "nenhum gate que falhou foi registrado", "AC-4 pt-BR: no failed gate recorded",
    "AC-4 the pt-BR catalog has no feed.no_gate (has %r)" % pt.get("feed.no_gate"))
chk(pt.get("feed.exit") == "terminou com exit {n}" and pt.get("disp.cycle_exit", "").endswith("e terminou com exit {exit}"),
    "AC-4 pt-BR: `ended with exit N` alone and after a cycle", "AC-4 pt-BR feed.exit is %r" % pt.get("feed.exit"))

# ---- AC-5: a run that ended well keeps today's second line
chk(good.get("exit") == 0 and "last" not in good and good.get("pr") == 65 and good.get("column") == "Staged" and "failed" not in good,
    "AC-5 the API gives the good run its PR and column, and no last line (as before)",
    "AC-5 the good run's event changed: %s" % good)
chk(re.search(r"\be\.last\b", left) is None, "AC-5 feedLeft builds the line without e.last",
    "AC-5 feedLeft still builds the second line with e.last")
chk(0 <= left.find("feed.pr") < left.find("feed.now_in") < left.find("\"feed.step\""), "AC-5 the good run's line is PR #n, then now in <column>, then the step",
    "AC-5 feedLeft lost the order PR #n, now in <column>, step")
chk(bool(pt.get("feed.now_in")), "AC-5 pt-BR keeps `now in`", "AC-5 the pt-BR catalog lost `now in`")

# ---- AC-6 / AC-7 / AC-8: dates and times in the page's language, never the browser's (#122: Intl, CODE from the
# catalog the server put in the page, any of its languages)
fmts = (re.search(r"^const TIME = .*$", h, re.M) or [""])[0] + (re.search(r"^const DAY_LONG = .*$", h, re.M) or [""])[0]
chk(re.search(r'^const CODE = LANG\.language \|\| "en"', h, re.M) is not None and "navigator" not in h, "AC-6 the page's language is the catalog's, falling back to English, never the browser's",
    "AC-6 CODE does not come from the catalog the server put in the page")
chk('TIME = new Intl.DateTimeFormat(CODE, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" })' in fmts and 'DAY_LONG = new Intl.DateTimeFormat(CODE, { weekday: "long", day: "numeric", month: "long" })' in fmts,
    "AC-6 the day header and the times format in the page's language (weekday and month long, 24-hour)", "AC-6 the Intl formats are not the page's language's")
chk("DAY_LONG.format(new Date(e.ts))" in rf and 'class="fday cap"' in rf and re.search(r'head = d === day \? "" : `<li class="fday cap">', rf) is not None and re.search(undef, rf) is None,
    "AC-7 the Feed's day header takes that format, in its shape", "AC-7 the Feed's day header does not take DAY_LONG")
chk("TIME.format(d)" in when and "DAY.format(d)" in when and "TIME.format(new Date(iso))" in hhmm and re.search(undef, when + hhmm) is None,
    "AC-8 when() and hhmm() format in the page's language, 24-hour", "AC-8 when() or hhmm() do not use the page's formats")
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
