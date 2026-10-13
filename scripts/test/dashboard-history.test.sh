#!/usr/bin/env bash
# #130: the Today panel becomes the factory's History, with a period to choose. The server computes the period, its
# neighbours and every figure (/api/history/<project>); what happens in the browser is read from the page as text,
# as the other dashboard tests do. The screen itself is checked by UX/UI in validation.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
# a day is the machine's calendar day: never straddle midnight, and leave today's runs a few minutes behind now
[ "$(date +%H%M)" -ge 2357 ] && sleep 200
[ "$(date +%H%M)" -lt 0012 ] && sleep 720
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
T="$C/projects/C--x--shipfloor-projects-shop-control"; mkdir -p "$T"

day() { date -d "$1" +%F; }                                        # day "-2 days" -> YYYY-MM-DD
at() { date -d "$1" --iso-8601=seconds; }                          # at "2026-10-11 10:00" -> local time with its offset
D0="$(day today)"; D1="$(day '-1 day')"; D2="$(day '-2 days')"; D3="$(day '-3 days')"; D5="$(day '-5 days')"
D9="$(day '-9 days')"; D20="$(day '-20 days')"; D60="$(day '-60 days')"; D93="$(day '-92 days')"; TOMORROW="$(day '+1 day')"
run() {  # run <day> <issue> <stage> <start> <end> <exit>: one run in that card's log of the day
  printf '== start /sf:%s %s %s pid=1\n== end /sf:%s %s exit=%s %s\n' "$3" "$2" "$4" "$3" "$2" "$6" "$5" >> "$P/logs/$1-$2-$3.log"
}
sess() {  # sess <name> <issue> <stage> <start> <model> <input tokens>: a session of the card's run
  { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<command-name>/sf:%s</command-name>\\n<command-args>%s</command-args>"}}\n' "$4" "$3" "$2"
    printf '{"type":"assistant","timestamp":"%s","message":{"id":"m-%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":0}}}\n' "$4" "$1" "$5" "$6"; } > "$T/$1.jsonl"
}
# today: #5 refine clean (US$ 4.00, opus 1M input) then develop failed
S0="$(at '-9 min')"; E0="$(at '-7 min')"; S0b="$(at '-6 min')"; E0b="$(at '-4 min')"
run "$D0" 5 refine "$S0" "$E0" 0; run "$D0" 5 develop "$S0b" "$E0b" 4
sess s5 5 refine "$S0" claude-opus-5-5 1000000
# two days ago: #6 develop clean (US$ 2.00) and its deploy, clean: #6 reached Done
run "$D2" 6 develop "$(at "$D2 09:00")" "$(at "$D2 09:30")" 0; run "$D2" 6 deploy "$(at "$D2 10:00")" "$(at "$D2 10:06")" 0
sess s6 6 develop "$(at "$D2 09:01")" claude-opus-5-5 500000
# five days ago: #7 refine clean, no session
run "$D5" 7 refine "$(at "$D5 14:00")" "$(at "$D5 14:20")" 0
# three days ago, a busy day: 60 refine runs of #10 (the runs table has two pages)
for i in $(seq 0 59); do m=$(printf '%02d' $((i % 60))); h=$((8 + i / 60)); run "$D3" 10 refine "$(at "$D3 0$h:$m:00")" "$(at "$D3 0$h:$m:30")" 0; done
# the 7 days before: #8 deployed clean nine days ago
run "$D9" 8 deploy "$(at "$D9 11:00")" "$(at "$D9 11:05")" 0
# twenty days ago: #9 ran on a model with no price
run "$D20" 9 refine "$(at "$D20 10:00")" "$(at "$D20 10:10")" 0
sess s9 9 refine "$(at "$D20 10:01")" claude-mystery-1 1000
# titles and the issues' creation (the median from Inbox to Done): #6 opened two days before its deploy
D4="$(day '-4 days')"; D10="$(day '-10 days')"
printf '5\tFive\n6\tSix\t%s\n7\tSeven\n8\tEight\t%s\n9\tNine\n10\tTen\n' "$(at "$D4 10:06")" "$(at "$D10 11:05")" > "$FAKE_GH_DIR/titles.tsv"
WAIT6=$(( $(date -d "$D2 10:06" +%s) - $(date -d "$D4 10:06" +%s) )); WAIT8=$(( $(date -d "$D9 11:05" +%s) - $(date -d "$D10 11:05" +%s) ))  # two days and one, whatever the clock changes
printf '5\tCoding\n6\tDone\n7\tSpec Review\n9\tInbox\n10\tReady for Dev\n' > "$P/board.tsv"

export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
code() { curl -s -o /dev/null -w '%{http_code}' -H "X-Shipfloor-Token: $tok" "$@"; }
hq() { curl -s -H "X-Shipfloor-Token: $tok" "$base/api/history/shop?$1" | $PY -c "import json,sys; d=json.load(sys.stdin); $2" 2>&1 | tr -d '\r'; }
is() { [ "$1" = "$2" ] && pass "$3" || fail "$3: got '$1', want '$2'"; }
curl -s -H "X-Shipfloor-Token: $tok" "$base/api/overview" > /dev/null   # the first read asks GitHub for the titles

# ---- AC-1: by day over 7 and 30 days, every slot in place; Today by hour
is "$(hq 'days=7' 'print(d["unit"], len(d["buckets"]), [b["day"] for b in d["buckets"]][0], [b["day"] for b in d["buckets"]][-1])')" "day 7 $(day '-6 days') $D0" "AC-1 7 days: seven slots by day, ending today"
is "$(hq 'days=7' 'print([(b["day"], b["ok"], b["failed"], b["cost"]) for b in d["buckets"] if b["ok"] + b["failed"]])')" \
   "[('$D5', 1, 0, 0.0), ('$D3', 60, 0, 0.0), ('$D2', 2, 0, 2.0), ('$D0', 1, 1, 4.0)]" "AC-1 7 days: the days with runs have the right counts and spend"
is "$(hq 'days=7' 'print(sum(1 for b in d["buckets"] if not b["ok"] + b["failed"]), all(b["cost"] == 0 for b in d["buckets"] if not b["ok"] + b["failed"]))')" "3 True" "AC-1 7 days: the empty days keep their place, empty"
is "$(hq 'days=30' 'print(d["unit"], len(d["buckets"]), sum(b["ok"] + b["failed"] for b in d["buckets"]))')" "day 30 67" "AC-1 30 days: thirty slots by day"
is "$(hq '' 'print(d["unit"], d["days"], d["from"] == d["to"], [b["h"] for b in d["buckets"]] == list(range(0, int(__import__("time").strftime("%H")) + 1)))')" "hour 1 True True" "AC-1 Today: by hour, from 0h to the current hour"
h0="$(date -d "$E0" +%-H)"; h0b="$(date -d "$E0b" +%-H)"
is "$(hq 'days=1' "print(sum(b['ok'] for b in d['buckets'] if b['h'] == $h0), sum(b['failed'] for b in d['buckets'] if b['h'] == $h0b), round(sum(b['cost'] for b in d['buckets']), 2))")" "1 1 4.0" "AC-1 Today: the runs and spend at the hour they ended"

# ---- AC-2: the arrows' neighbours, a custom range, the refused ones
is "$(hq 'days=1' 'print(d["present"], d["next"], d["now"], d["prev"])')" "True None None {'from': '$D1', 'to': '$D1'}" "AC-2 Today: the previous period is yesterday, there is no next"
is "$(hq "from=$D1&to=$D1" 'print(d["present"], d["next"], d["now"], d["unit"])')" "False {'from': '$D0', 'to': '$D0'} {'from': '$D0', 'to': '$D0'} hour" "AC-2 yesterday: the next period is today again"
is "$(hq 'days=7' 'print(d["prev"])')" "{'from': '$(day '-13 days')', 'to': '$(day '-7 days')'}" "AC-2 7 days: the previous 7 days end the day before"
is "$(hq "from=$D5&to=$D2" 'print(d["days"], [b["day"] for b in d["buckets"]], d["totals"]["ok"])')" "4 ['$D5', '$(day '-4 days')', '$D3', '$D2'] 63" "AC-2 a custom range shows exactly its days"
is "$(code "$base/api/history/shop?from=$D2&to=$D5")" 400 "AC-2 an end before its start is refused"
is "$(code "$base/api/history/shop?from=$D0&to=$TOMORROW")" 400 "AC-2 a future date is refused"
is "$(code "$base/api/history/shop?from=$D93&to=$D0")" 400 "AC-2 more than 92 days is refused"
is "$(code "$base/api/history/shop?from=$(day '-91 days')&to=$D0")" 200 "AC-2 92 days is accepted"
is "$(code "$base/api/history/shop?from=12-10-2026&to=$D0")" 400 "AC-2 a malformed date is refused"
is "$(code "$base/api/history/shop?days=0")" 400 "AC-2 days=0 is refused"
is "$(code "$base/api/history/nope")" 404 "AC-2 an unknown project is 404"
is "$(curl -s -o /dev/null -w '%{http_code}' "$base/api/history/shop")" 403 "AC-2 no token, no history"

# ---- AC-4: the totals and the previous period's, the median from Inbox to Done, a stage's time over the period
is "$(hq 'days=7' 't=d["totals"]; print(t["done"], t["ok"], t["failed"], t["cost"], t["unpriced"], t["median_s"], t["median_of"])')" "1 64 1 6.0 0 $WAIT6 1" "AC-4 7 days: cards done, runs clean and failed, spend and the median (two days)"
is "$(hq 'days=7' 't=d["previous"]; print(t["done"], t["ok"], t["failed"], t["median_s"])')" "1 1 0 $WAIT8" "AC-4 7 days: the 7 days before, for the comparisons"
is "$(hq 'days=1' 't=d["totals"]; print(t["done"], t["median_s"], t["median_of"])')" "0 None 0" "AC-4 Today: no card done, no median (a dash, not zero)"
is "$(hq 'days=7' 'print(sorted(d["typical_s"].items()))')" "[('deploy', 360), ('develop', 1800), ('refine', 30)]" "AC-4 7 days: a stage usually takes, over the period"
is "$(hq "from=$D5&to=$D5" 'print(d["typical_s"])')" "{'refine': 1200}" "AC-4 one day: a stage usually takes, over that day only"

# ---- AC-5: the runs of the period page by page, newest first; the totals equal the rows; the cards by cost
is "$(hq 'days=7' 'print(d["runs_total"], d["page"], d["pages"], len(d["runs"]), d["runs"][0]["issue"], d["runs"][0]["stage"], d["runs"][0]["title"])')" "65 1 2 50 5 develop Five" "AC-5 page 1: 50 of 65 runs, the newest first"
is "$(hq 'days=7&page=2' 'print(d["page"], len(d["runs"]), d["runs"][-1]["issue"])')" "2 15 7" "AC-5 page 2: the other 15, the oldest last"
all="$(for pg in 1 2; do hq "days=7&page=$pg" 'print(json.dumps(d["runs"]))'; done | $PY -c '
import json, sys
rows = [r for line in sys.stdin for r in json.loads(line)]
ends = [r["end"] for r in rows]
print(len(rows), len({(r["log"], r["start"]) for r in rows}), round(sum(r["cost"] for r in rows if r["cost"] is not None), 2), sum(r["exit"] == 0 for r in rows), sum(r["exit"] != 0 for r in rows))')"
is "$all" "65 65 6.0 64 1" "AC-5 every page together: each run once, and the spend and counts equal the totals"
is "$(hq 'days=30' 'print([(c["issue"], c["column"], c["runs"], c["cost"]) for c in d["cards"]])')" \
   "[(5, 'Coding', 2, 4.0), (6, 'Done', 2, 2.0), (7, 'Spec Review', 1, 0.0), (8, None, 1, 0.0), (10, 'Ready for Dev', 60, 0.0), (9, 'Inbox', 1, None)]" "AC-5 the cards of the period: the costliest first, the unpriced last"

# ---- AC-6: a period with no run says so; a missing price is $ ?
is "$(hq "from=$D60&to=$D60" 'print(d["empty"], d["runs"], d["cards"], d["totals"]["ok"] + d["totals"]["failed"])')" "True [] [] 0" "AC-6 a period with no run is empty"
is "$(hq 'days=30' 'print(d["totals"]["unpriced"], d["empty"])')" "1 False" "AC-6 a run with no price is counted apart, as unpriced"
is "$(hq "from=$D20&to=$D20" 'print(d["runs"][0]["cost"], d["buckets"][10]["unpriced"])')" "None 1" "AC-6 its row and its hour have no figure"

# ---- the page (AC-2, AC-3, AC-4, AC-6, AC-7, AC-8), read as text
out="$("$FACTORY_PYTHON" - "$FACTORY_DIR/dashboard.html" "$FACTORY_DIR/lang/dashboard.pt-BR.json" "$FACTORY_DIR/dashboard.py" <<'PY'
import json, re, sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0] + "/test"); import page_text  # the page asks for its text by key (#122)
raw = open(sys.argv[1], encoding="utf-8").read()
h = page_text.english(raw)
EN = page_text.EN
py = open(sys.argv[3], encoding="utf-8").read()
res = []
def check(name, cond, why=""):
    res.append(("ok " if cond else "no ") + (name if cond else f"{name}: {why}"))
def src(start, text=h):
    i = text.find(start)
    if i < 0: return ""
    j = text.find("\n}", i)
    return text[i:j + 2]
tel, ctl, step, setp = src("function renderTelem"), src("function renderHistCtl"), src("function histStep"), src("function histSet")
rtel, rctl = src("function renderTelem", raw), src("function renderHistCtl", raw)
# AC-2: the period control, the arrows, the custom range
check("AC-2 the period group has Today, 7 days, 30 days and Custom with aria-pressed", all(x in ctl for x in ('role="group" aria-label="Period"', "[1, 7, 30]", ">Custom<", "aria-pressed"))
      and 't(n === 1 ? "hist.p.today" : "hist.p.days", { n })' in rctl and EN["hist.p.today"] == "Today" and EN["hist.p.days"] == "{n} days")
check("AC-2 Previous and Next period arrows", 'aria-label="Previous period"' in ctl and 'aria-label="Next period"' in ctl)
check("AC-2 Next is unavailable at the present, still focusable", 'aria-disabled="true" title="This is the current period"' in ctl and "disabled>" not in ctl)
check("AC-2 the arrows step by the period's length and never past today", "shift(from, -n)" in step and "> now ? now" in step)
check("AC-2 a custom range: two date fields with max today", 'type="date"' in ctl and 'max="${now}"' in ctl and "From<" in ctl and "To<" in ctl)
hd = src("function histDates")
for m in ("The end date is before the start date.", "That date is in the future.", "Pick ${HDAYS} days at most."):
    check(f"AC-2 the custom range refuses with {m!r}", m in hd)
check("AC-2 the longest range is 92 days", "const HDAYS = 92;" in h)
check("AC-2 a refused range marks its field and keeps the last valid period", 'aria-invalid", "true"' in hd and "return at.setAttribute" in hd)
# AC-3: a day opens by hour, Back to now
check("AC-3 a day of a chart by day is a button that asks for that day", 'class="dslot" data-hday=' in tel and "histSet({ from: t.dataset.hday, to: t.dataset.hday })" in h)
check("AC-3 opening a day moves the focus to Back to now", re.search(r"dataset\.hday\) \{ histSet[^\n]*data-hnow", h) is not None)
check("AC-3 Back to now shows only away from the present", '${present ? "" : `<button class="lnk" data-hnow>Back to now</button>`}' in ctl)
check("AC-3 Back to now returns to the current period of that length", "histSet({ days: histSpan().n })" in h)
check("AC-3 the arrow keys, Home and End move between the days", all(k in h for k in ('"ArrowLeft", "ArrowRight", "Home", "End"', 'tabindex="${i === f ? 0 : -1}"')))
# AC-4: the totals in words, never an arrow
for l in ("Cards done", "Runs", "Spent est.", "Inbox to Done, median"):
    check(f"AC-4 the total {l!r}", f'["{l}"' in tel)
for k in ("hist.cmp.more", "hist.cmp.fewer", "hist.cmp.same", "hist.cmp.nothing", "hist.no_done", "hist.cmp.faster", "hist.cmp.slower", "hist.cmp.no_price"):
    check(f"AC-4 the comparisons say {EN[k]!r}", k in rtel)
check("AC-4 the comparison names the period before", EN["hist.cmp.more"] == "{d} more than {n, plural, one {the day before} other {the # days before}}" and EN["hist.cmp.nothing"] == "{n, plural, one {nothing the day before} other {nothing in the # days before}}")
check("AC-4 no arrow glyph in the comparisons", not re.search("[↑↓▲▼]", tel + "".join(EN[k] for k in EN if k.startswith("hist."))))
check("AC-4 a median with no card done is a dash", 'T.median_s == null ? "–"' in tel)
check("AC-4 a stage usually takes reads the period's figures", "d.typical_s" in tel and "p.typical_s" not in tel)
# AC-5: the maximized strip and tables
check("AC-5 maximized, the totals are a strip of four columns", ".maxed .htot { grid-template-columns: repeat(4, minmax(0, 1fr));" in h)
check("AC-5 the runs table loads more pages on demand", '"hist.more")' in rtel and EN["hist.more"] == "Show more runs" and "page=${H.page + 1}" in h and 't("hist.shown", { i: rows.length, n: d.runs_total })' in rtel)
check("AC-5 the cards table, a row opening the card on Sessions", "Cards of the period, by est. cost" in tel and 'data-go="sessions"' in tel)
# AC-6: the empty period and the missing price
check("AC-6 an empty period says so and offers the previous one", "No run ended in this period." in tel and 't("hist.see_prev", { n })' in rtel and EN["hist.see_prev"] == "{n, plural, one {See the day before} other {See the # days before}}")
check("AC-6 the empty period draws no chart", tel.index("if (d.empty)") < tel.index("const totals"))
check("AC-6 a missing price shows $ ?", "money(null)" in tel and "$ ?" in h)
# AC-7: the period survives a reload; the summary line stays about today
check("AC-7 the period is read from localStorage at load", 'localStorage.getItem("shipfloor.history")' in h)
check("AC-7 the period is written on every change", 'localStorage.setItem("shipfloor.history", JSON.stringify(H.sel))' in setp)
check("AC-7 Today, 7 days and 30 days are kept relative to now", "{ days: v.days }" in h and "histSet({ days: +t.dataset.hp })" in h)
check("AC-7 the history is read only while the panel is open, at most every 10 s", "!S.show.history" in src("async function loadHistory") and "10000" in src("async function loadHistory"))
check("AC-7 the summary line still reads today's figures", "o.today.runs" in src("function renderStrip") and "o.today.cost" in src("function renderStrip"))
check("AC-7 the overview no longer carries hours and ended", '"hours": [dict(' not in py and '"ended": sorted(' not in py)
# AC-8: History, never Today as the panel's name, in every language
check("AC-8 the panel is #history, its toggle data-show=history", 'id="history" data-maxable="history"' in h and 'data-show="history"' in h and 'id="today"' not in h)
check("AC-8 the heading is History and the period", '<h1 class="g" id="ht"><span data-i="hist.h">History</span> <span class="hper" id="hper" aria-live="polite">' in h)
check("AC-8 the heading names the period", all(x in h for x in ('"· today"', '"· yesterday"', "formatRange")) and 't(s.days === 1 ? "hist.per.today" : "hist.per.days", { n: s.days })' in raw and EN["hist.per.days"] == "· last {n} days")
check("AC-8 nothing calls the panel Today", 'aria-label="Minimize today"' not in h and "S.show.today" not in h and ">Today</h1>" not in h and "panel.today" not in raw)
R = page_text.render
pt = [(("hist.h", {}), "Histórico"), (("hist.per.today", {}), "· hoje"), (("hist.per.yesterday", {}), "· ontem"), (("hist.per.days", {"n": 7}), "· últimos 7 dias"),
      (("hist.per.days", {"n": 30}), "· últimos 30 dias"), (("hist.period", {}), "Período"), (("hist.p.today", {}), "Hoje"), (("hist.p.days", {"n": 7}), "7 dias"),
      (("hist.p.custom", {}), "Personalizado"), (("hist.prev", {}), "Período anterior"), (("hist.next", {}), "Próximo período"),
      (("hist.current", {}), "Este é o período atual"), (("hist.now", {}), "Voltar para agora"), (("hist.from", {}), "De"), (("hist.to", {}), "Até"),
      (("hist.bad.order", {}), "A data final é anterior à inicial."), (("hist.bad.future", {}), "Essa data está no futuro."),
      (("hist.bad.long", {"n": 92}), "Escolha no máximo 92 dias."), (("panel.history.max", {}), "Maximizar o histórico"), (("panel.history.restore", {}), "Restaurar o histórico"),
      (("panel.history.min", {}), "Minimizar o histórico"), (("panel.history.expand", {}), "Expandir o histórico"),
      (("hist.t.done", {}), "Cards concluídos"), (("hist.t.median", {}), "Inbox a Concluído, mediana"),
      (("hist.cmp.more", {"d": 3, "n": 7}), "3 a mais que nos 7 dias anteriores"), (("hist.cmp.fewer", {"d": 2, "n": 1}), "2 a menos que no dia anterior"),
      (("hist.cmp.same", {"n": 30}), "o mesmo que nos 30 dias anteriores"), (("hist.cmp.same", {"n": 1}), "o mesmo que no dia anterior"),
      (("hist.cmp.nothing", {"n": 1}), "nada no dia anterior"), (("hist.cmp.nothing", {"n": 7}), "nada nos 7 dias anteriores"),
      (("hist.cmp.est_more", {"d": "$1,20", "n": 7}), "est. $1,20 a mais que nos 7 dias anteriores"), (("hist.cmp.est_less", {"d": "$0,50", "n": 1}), "est. $0,50 a menos que no dia anterior"),
      (("hist.cmp.faster", {"d": "12 min", "n": 7}), "12 min mais rápido que nos 7 dias anteriores"), (("hist.cmp.slower", {"d": {"key": "hist.span.d", "params": {"n": 2}}, "n": 1}), "2 dias mais lento que no dia anterior"),
      (("hist.no_done", {}), "nenhum card chegou a Concluído"), (("hist.cmp.no_price", {}), "sem comparação: falta um preço"),
      (("hist.runs_d", {}), "Execuções encerradas, por dia"), (("hist.spend_d", {}), "Gasto por dia"),
      (("hist.reading", {}), "Lendo o histórico…"), (("hist.empty", {}), "Nenhuma execução terminou neste período."),
      (("hist.see_prev", {"n": 1}), "Ver o dia anterior"), (("hist.see_prev", {"n": 7}), "Ver os 7 dias anteriores"),
      (("hist.ended", {}), "Execuções encerradas"), (("hist.shown", {"i": 50, "n": 213}), "50 de 213 execuções"), (("hist.runs_n", {"n": 213}), "213 execuções"), (("hist.runs_n", {"n": 1}), "1 execução"),
      (("hist.more", {}), "Mostrar mais execuções"), (("hist.more_failed", {}), "Não foi possível ler as próximas execuções."),
      (("hist.cards", {}), "Cards do período, por custo est."), (("hist.th.cost", {}), "Inbox até agora"),
      (("hist.slot.open", {"day": "seg. 6 de out.", "what": {"key": "hist.slot.none"}}), "seg. 6 de out.: nenhuma execução. Abrir o dia"),
      (("hist.slot.open", {"day": "seg. 6 de out.", "what": R("pt-BR", "today.spend.sum", spent="$1,20").rstrip(".")}), "seg. 6 de out.: $1,20 est. Abrir o dia")]  # the page drops the label's own period
for (k, v), want in pt:
    got = R("pt-BR", k, **v)
    check(f"AC-8 pt-BR {k} {v}", got == want, f"reads {got!r}")
for r in res: print(r)
PY
)"
while IFS= read -r line; do case "$line" in "ok "*) pass "${line#ok }" ;; *) fail "${line#no }" ;; esac; done <<< "$out"
finish
