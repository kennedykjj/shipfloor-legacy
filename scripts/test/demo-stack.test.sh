#!/usr/bin/env bash
# The demo stack (card #72): scripts/test/demo-stack.sh up / down serves the dashboard on sample data (dashboard.py's
# --token is in dashboard-server.test.sh). Every server runs on a port the system gave, under a stack name of its own, and is
# stopped by the trap even when an assertion fails. Nothing here reads or writes the real ~/.shipfloor or calls the real gh.
source "$(dirname "$0")/lib.sh"
PY=python3; $PY -c '' 2>/dev/null || PY=python
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
T="$(mktemp -d)"; DEMO="$FACTORY_DIR/test/demo-stack.sh"
RUN="qa72-$$-$RANDOM"; NAMES=""; PIDS=""; EXTRA=""
STATE_ROOT="${TMPDIR:-/tmp}/shipfloor-demo"
TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 90"

cleanup() {
  local n
  for n in $NAMES; do
    [ -f "$DEMO" ] && SHIPFLOOR_STACK="$n" $TMO bash "$DEMO" down >/dev/null 2>&1
    rm -rf "$STATE_ROOT/$n"
  done
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null
  rm -rf "$T" $EXTRA
}
trap cleanup EXIT

free_port() { $PY -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' | tr -d '\r'; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null; }
alive() { if command -v tasklist >/dev/null 2>&1; then tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -q "[[:space:]]$1[[:space:]]"; else kill -0 "$1" 2>/dev/null; fi; }
# q <json file> <python expr on d>: prints the value, or ERR: <why>
q() { $PY -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); print($2)" "$(nat "$1")" 2>/dev/null | tail -n 1 | tr -d '\r'; [ "${PIPESTATUS[0]}" -eq 0 ] || echo "unavailable (no JSON from the server)"; }
# eq <what> <got> <want>
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1: got '$2', want '$3'"; }

# up_demo <name> <port> <token> [VAR=value ...]: runs `demo-stack.sh up` with its output in files (a server that
# held the pipe must not hang the test); sets UP_RC, UP_OUT, UP_ERR
up_demo() {
  local name="$1" port="$2" tok="$3"; shift 3
  case " $NAMES " in *" $name "*) ;; *) NAMES="$NAMES $name" ;; esac
  if [ ! -f "$DEMO" ]; then UP_RC=127; UP_OUT=""; UP_ERR="$DEMO does not exist"; return; fi
  env SHIPFLOOR_STACK="$name" SHIPFLOOR_PORT_WEB="$port" SHIPFLOOR_DEMO_TOKEN="$tok" "$@" \
    $TMO bash "$DEMO" up > "$T/up-$name.out" 2> "$T/up-$name.err" < /dev/null
  UP_RC=$?; UP_OUT="$(tr -d '\r' < "$T/up-$name.out")"; UP_ERR="$(tr -d '\r' < "$T/up-$name.err" | tail -n 3)"
}
down_demo() { [ -f "$DEMO" ] || { DOWN_RC=127; return; }; SHIPFLOOR_STACK="$1" $TMO bash "$DEMO" down > "$T/down-$1.out" 2>&1 < /dev/null; DOWN_RC=$?; }
api() { curl -s --max-time 10 -H "X-Shipfloor-Token: $3" "http://127.0.0.1:$2$4" > "$T/$1" 2>/dev/null; }

P1="$(free_port)"; TOK1="tok-$RANDOM"; N1="$RUN-a"; URL1="http://127.0.0.1:$P1/?t=$TOK1"

# --- AC-1: one command starts the demo; / answers 200; the overview has two projects and six or more columns
up_demo "$N1" "$P1" "$TOK1"
eq "AC-1 'demo-stack.sh up' exits 0 (stderr: $UP_ERR)" "$UP_RC" "0"
eq "AC-1 'up' prints the URL with the chosen token" "$(printf '%s' "$UP_OUT" | tail -n 1)" "$URL1"
eq "AC-1 GET / answers 200" "$(code "http://127.0.0.1:$P1/")" "200"
eq "AC-1 GET /api/overview with the token answers 200" "$(code -H "X-Shipfloor-Token: $TOK1" "http://127.0.0.1:$P1/api/overview")" "200"
api ov1.json "$P1" "$TOK1" /api/overview
eq "AC-1 the overview has two projects" "$(q "$T/ov1.json" "len(d['projects'])")" "2"
got="$(q "$T/ov1.json" "max(len({c['column'] for c in p['cards']}) for p in d['projects'])")"
[ "$got" -ge 6 ] 2>/dev/null && pass "AC-1 a project has cards in $got columns (6 or more)" || fail "AC-1 the most columns a project has cards in: $got (want 6 or more)"

# --- AC-3 and AC-4 read the same running demo (before it is stopped for AC-2)
# AC-3: what each view reads
eq "AC-3 a card awaits the owner in Spec Review" "$(q "$T/ov1.json" "any(c['column']=='Spec Review' and c['awaiting'] for p in d['projects'] for c in p['cards'])")" "True"
eq "AC-3 a card awaits the owner in Staged" "$(q "$T/ov1.json" "any(c['column']=='Staged' and c['awaiting'] for p in d['projects'] for c in p['cards'])")" "True"
eq "AC-3 a run is live with a reported step" "$(q "$T/ov1.json" "any(r.get('step') and not r.get('orphan') for r in d['runs'])")" "True"
eq "AC-3 a card is running on the board" "$(q "$T/ov1.json" "any(c['running'] for p in d['projects'] for c in p['cards'])")" "True"
eq "AC-3 a card is blocked for the owner" "$(q "$T/ov1.json" "any(c['blocked']=='owner' for p in d['projects'] for c in p['cards'])")" "True"
eq "AC-3 a card is blocked by infrastructure" "$(q "$T/ov1.json" "any(c['blocked']=='infra' for p in d['projects'] for c in p['cards'])")" "True"
api feed1.json "$P1" "$TOK1" /api/feed
eq "AC-3 the feed has dispatcher lines" "$(q "$T/feed1.json" "any(e.get('source')=='dispatcher' for e in d['events'])")" "True"
eq "AC-3 the feed has runs" "$(q "$T/feed1.json" "any(e.get('issue') for e in d['events'])")" "True"
api set1.json "$P1" "$TOK1" /api/settings
eq "AC-3 the settings have both projects" "$(q "$T/set1.json" "len(d['projects'])")" "2"

# AC-4: today's runs, costs, the unpriced session
got="$(q "$T/ov1.json" "d['today']['ok']")"
[ "$got" -ge 1 ] 2>/dev/null && pass "AC-4 today has $got clean run(s)" || fail "AC-4 today's clean runs: $got (want 1 or more)"
got="$(q "$T/ov1.json" "d['today']['failed']")"
[ "$got" -ge 1 ] 2>/dev/null && pass "AC-4 today has $got failed run(s)" || fail "AC-4 today's failed runs: $got (want 1 or more)"
A="$(q "$T/ov1.json" "max(d['projects'], key=lambda p: len(p['cards']))['slug'] if d['projects'] else 'none'")"
CARDS="$(q "$T/ov1.json" "' '.join(str(c['issue']) for p in d['projects'] if p['slug']==max(d['projects'], key=lambda p: len(p['cards']))['slug'] for c in p['cards'])")"
unpriced=""; nullcost=""; ncards=0
case "$A" in none|unavailable*) CARDS="" ;; esac
for n in $CARDS; do
  ncards=$((ncards+1))
  api "card-$n.json" "$P1" "$TOK1" "/api/card/$A/$n"
  [ "$(q "$T/card-$n.json" "any(s['cost'] is None for s in d['sessions'])")" = "True" ] && unpriced="$unpriced $n"
  [ "$(q "$T/ov1.json" "[c['cost'] for p in d['projects'] if p['slug']=='$A' for c in p['cards'] if c['issue']==$n][0] is None")" = "True" ] && nullcost="$nullcost $n"
done
[ "$ncards" -ge 1 ] && pass "AC-4 project A has $ncards cards" || fail "AC-4 no cards in the biggest project ($A)"
[ -n "$unpriced" ] && pass "AC-4 a session of an unpriced model has cost null (card$unpriced)" || fail "AC-4 no card has a session with cost null (the unpriced model)"
[ -n "$unpriced" ] && [ "$(echo $nullcost)" = "$(echo $unpriced)" ] && pass "AC-4 only the card with the unpriced session lacks a cost (never a zero standing for it)" || fail "AC-4 cards without a cost: '$nullcost', cards with an unpriced session: '$unpriced' (want the same, not empty)"
got="$(q "$T/ov1.json" "sum(1 for p in d['projects'] if p['slug']=='$A' for c in p['cards'] if c['cost'] is not None and c['cost'] > 0)")"
[ "$got" -ge 1 ] 2>/dev/null && pass "AC-4 $got card(s) of project A have an estimated cost" || fail "AC-4 no card of project A has an estimated cost above zero: $got"

# --- AC-2: stopped and started again with the same port and token, the same URL answers
down_demo "$N1"
up_demo "$N1" "$P1" "$TOK1"; UPRC2=$UP_RC
eq "AC-2 the second 'up' exits 0 (stderr: $UP_ERR)" "$UP_RC" "0"
eq "AC-2 the same URL answers 200 again" "$(code "http://127.0.0.1:$P1/")" "200"
eq "AC-2 the same token still reads the overview" "$(code -H "X-Shipfloor-Token: $TOK1" "http://127.0.0.1:$P1/api/overview")" "200"

# --- AC-7: down stops it: the port refuses, the process is gone, the state folder is removed
S1="$STATE_ROOT/$N1"
[ -d "$S1" ] && pass "AC-7 while running, the state folder exists" || fail "AC-7 no state folder at $S1 while the demo runs"
for f in home claude gh server.log pid; do [ -e "$S1/$f" ] && pass "AC-7 the state folder holds $f" || fail "AC-7 the state folder holds no $f"; done
PID1="$(tr -d '\r\n ' < "$S1/pid" 2>/dev/null)"
[ -n "$PID1" ] && alive "$PID1" && pass "AC-7 the pid file names a live process" || fail "AC-7 the pid file ('$PID1') does not name a live process"
down_demo "$N1"
eq "AC-7 'down' exits 0" "$DOWN_RC" "0"
[ "$UPRC2" = 0 ] && [ "$(code "http://127.0.0.1:$P1/")" = "000" ] && pass "AC-7 the port no longer answers" || fail "AC-7 the demo did not run, or its port still answers"
if [ -n "$PID1" ] && ! alive "$PID1"; then pass "AC-7 the server's process is gone"; else fail "AC-7 the server's process ('$PID1') is still there, or there was no pid"; fi
[ "$UPRC2" = 0 ] && [ ! -e "$S1" ] && pass "AC-7 the state folder is removed" || fail "AC-7 the state folder is still there: $(ls "$S1" 2>&1 | tr '\n' ' ')"
down_demo "$N1"
eq "AC-7 'down' with nothing to stop exits 0" "$DOWN_RC" "0"

# --- AC-6: two demos; stopping one leaves the other answering with its own data
P2="$(free_port)"; P3="$(free_port)"; while [ "$P3" = "$P2" ] || [ "$P3" = "$P1" ]; do P3="$(free_port)"; done
N2="$RUN-b"; N3="$RUN-c"; TOK2="tok-$RANDOM"; TOK3="tok-$RANDOM"
up_demo "$N2" "$P2" "$TOK2"; RC2=$UP_RC
up_demo "$N3" "$P3" "$TOK3"; RC3=$UP_RC
eq "AC-6 both demos start" "$RC2 $RC3" "0 0"
eq "AC-6 both answer 200 before one is stopped" "$(code "http://127.0.0.1:$P2/") $(code "http://127.0.0.1:$P3/")" "200 200"
[ "$N2" != "$N3" ] && [ -d "$STATE_ROOT/$N2" ] && [ -d "$STATE_ROOT/$N3" ] && pass "AC-6 each demo has a state folder of its own" || fail "AC-6 the two demos do not have two state folders"
down_demo "$N2"
[ "$RC2" = 0 ] && [ "$(code "http://127.0.0.1:$P2/")" = "000" ] && pass "AC-6 the stopped demo's port refuses" || fail "AC-6 the demo did not start, or its port still answers after down"
eq "AC-6 the other demo still answers 200" "$(code "http://127.0.0.1:$P3/")" "200"
eq "AC-6 the other demo still serves its own data with its own token" "$(code -H "X-Shipfloor-Token: $TOK3" "http://127.0.0.1:$P3/api/overview")" "200"
api ov3.json "$P3" "$TOK3" /api/overview
eq "AC-6 the other demo still has its two projects" "$(q "$T/ov3.json" "len(d['projects'])")" "2"
[ "$RC2" = 0 ] && [ ! -e "$STATE_ROOT/$N2" ] && [ -d "$STATE_ROOT/$N3/home" ] && pass "AC-6 only the stopped demo's state folder is gone" || fail "AC-6 state folders after stopping one: $N2 exists=$([ -e "$STATE_ROOT/$N2" ] && echo yes || echo no), $N3/home exists=$([ -d "$STATE_ROOT/$N3/home" ] && echo yes || echo no)"
down_demo "$N3"

# --- AC-5: no network, no real gh, no real home: actions work on the sample and nothing is written outside the state
H1="$(mktemp -d)"; H2="$(mktemp -d)"; EXTRA="$H1 $H2"
printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/gh-called"\necho "no network" >&2\nexit 1\n' "$(nat "$T")" > "$T/failgh"; chmod +x "$T/failgh"
P5="$(free_port)"; TOK5="tok-$RANDOM"; N5="$RUN-e"
up_demo "$N5" "$P5" "$TOK5" HOME="$H1" USERPROFILE="$(nat "$H1")" SHIPFLOOR_HOME="$H2" FACTORY_GH="$T/failgh"
UP5=$UP_RC
eq "AC-5 the demo starts with an empty HOME, an empty SHIPFLOOR_HOME and a failing gh (stderr: $UP_ERR)" "$UP_RC" "0"
api ov5.json "$P5" "$TOK5" /api/overview
got="$(q "$T/ov5.json" "sum(1 for p in d['projects'] for c in p['cards'] if not c['title'])")"
eq "AC-5 every card still shows its title" "$got" "0"
CARD5="$(q "$T/ov5.json" "next(('%s %s' % (p['slug'], c['issue']) for p in d['projects'] for c in p['cards'] if c['column']=='Spec Review' and c['awaiting']), 'none')")"
SLUG5="${CARD5% *}"; NUM5="${CARD5#* }"
post() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST -H 'Content-Type: application/json' -H "X-Shipfloor-Token: $TOK5" -d "$2" "http://127.0.0.1:$P5$1" 2>/dev/null; }
eq "AC-5 approving a Spec Review card ($CARD5) answers 200" "$(post "/api/card/$SLUG5/$NUM5/approve" '{"column":"Spec Review"}')" "200"
col="no Spec Review card to approve"
[ "$SLUG5" != "none" ] && for _ in 1 2 3 4 5 6 7 8; do
  api ov5b.json "$P5" "$TOK5" /api/overview
  col="$(q "$T/ov5b.json" "[c['column'] for p in d['projects'] if p['slug']=='$SLUG5' for c in p['cards'] if c['issue']==$NUM5][0]")"
  [ "$col" = "Ready for Dev" ] && break; sleep 0.5
done
eq "AC-5 the approved card changes column in the sample board" "$col" "Ready for Dev"
POOL5="$(q "$T/ov5.json" "d['pool']['size']")"
eq "AC-5 pausing the factory answers 200" "$(post /api/settings/pause '{"paused":true}')" "200"
eq "AC-5 resuming the factory answers 200" "$(post /api/settings/pause '{"paused":false}')" "200"
eq "AC-5 a settings change answers 200" "$(post /api/settings/machine "{\"pool\":$POOL5}")" "200"
[ "$UP5" = 0 ] && eq "AC-5 the HOME the caller had is still empty" "$(find "$H1" -mindepth 1 2>/dev/null | head -n 3 | tr '\n' ' ')" "" || fail "AC-5 not checked: the demo did not start"
[ "$UP5" = 0 ] && eq "AC-5 the SHIPFLOOR_HOME the caller had is still empty" "$(find "$H2" -mindepth 1 2>/dev/null | head -n 3 | tr '\n' ' ')" "" || fail "AC-5 not checked: the demo did not start"
[ "$UP5" = 0 ] && [ ! -e "$T/gh-called" ] && pass "AC-5 the caller's gh was never called" || fail "AC-5 the caller's gh was called: $(head -n 2 "$T/gh-called")"
down_demo "$N5"

finish
