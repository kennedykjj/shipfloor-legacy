#!/usr/bin/env bash
# suite: integration
# gate.sh stack and the gates that take a stack slot, as real processes: here the processes are the behavior (slots
# leased across processes, the queue, waits on the clock, INT/TERM, the heartbeat that outlives `stack up`). One
# scenario per behavior, with the shortest waits. The stack's own decisions are stack-*.test.sh's; red/green's verdict
# on a needs_stack layer is py/gate_run.py's.
# uses gate.sh sf.py stack.py run.py main.py
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
PIDS=""
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; touch "$T"/go-g1 "$T"/go-g2 "$T"/go-g3 "$T"/go-g4 "$T"/go-g5; for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"
FIX="$FACTORY_DIR/test/fixture/factory.yml"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
stubs="$T/stubs"; mkdir -p "$stubs"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"; chmod +x "$stubs/lsof"; export PATH="$stubs:$PATH"
export FACTORY_HOME="$T/home"; mkdir -p "$FACTORY_HOME"
bin="$T/bin"; mkdir -p "$bin"
REALDATE="$(command -v date)"
machine() {  # machine <stacks> <port base> <stack_wait>: a fresh SHIPFLOOR_HOME with these settings
  export SHIPFLOOR_HOME; SHIPFLOOR_HOME="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"
  printf 'stacks: %s\nports: {base: %s, span: 10}\nstack_wait: %s\nstack_stale: 90\nstack_hold_max: 2700\n' "$1" "$2" "$3" > "$SHIPFLOOR_HOME/config.yml"
}
project() {  # project <file> <name> <stack: block...>: the fixture named <name> with this stack block
  local f="$1" name="$2"; shift 2
  sed -e '/^stack:/d' -e "s/^  name: shop\$/  name: $name/" "$FIX" > "$f"; printf '%s\n' "$@" >> "$f"
}
timed() {  # timed <cmd...>: T_OUT, T_ERR, T_RC and T_SECS (whole seconds)
  local s e; s="$("$REALDATE" +%s)"
  T_OUT="$("$@" 2> "$T/err")"; T_RC=$?
  e="$("$REALDATE" +%s)"; T_SECS=$((e - s)); T_ERR="$(cat "$T/err")"
}
until_ok() { local n=$(( $1 * 10 )) i; shift; for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
queued() { ls "$L/stack-queue" 2>/dev/null | grep -q -- "-$1\$"; }
up() { bash "$GATE" stack up "$1"; }
down() { bash "$GATE" stack down "$1" >/dev/null; }
r="$(new_repo)"; cd "$r"; mkdir -p web
TAB=$'\t'

# ---- two runs get two slots: their own ports and compose project, the slot's env and no AGHANIM_*; a third gives up
machine 2 21000 1
project "$T/s.yml" shop 'stack:' \
  "  up: 'echo \"up \$SHIPFLOOR_SLOT \$SHIPFLOOR_STACK \$SHIPFLOOR_PORT_WEB \$SHIPFLOOR_PORT_API\" >> \"$bin/calls\"; env | grep \"^AGHANIM_\" >> \"$bin/old\"; true'" \
  "  down: 'echo \"down \$SHIPFLOOR_SLOT\" >> \"$bin/calls\"'" '  ports: [web, api]' '  url: "http://localhost:{web}"' \
  "  health: \"file:///$(nat "$bin")/health\"" '  reject: "Runtime Error"' '  timeout: 1'
export FACTORY_CONFIG="$T/s.yml"; echo ok > "$bin/health"
[ "$(up validate-1)" = "http://localhost:21000" ] && pass "stack up prints the slot's URL and nothing else" || fail "stack up validate-1"
[ "$(FACTORY_LANGUAGE=pt-BR up validate-2)" = "http://localhost:21010" ] && pass "a second run gets the next slot (only the URL in pt-BR too)" || fail "stack up validate-2"
calls="$(cat "$bin/calls")"
assert_contains "$calls" "up 0 shipfloor-shop-0 21000 21001"
assert_contains "$calls" "up 1 shipfloor-shop-1 21010 21011"
[ ! -s "$bin/old" ] && pass "no AGHANIM_* variable in the slot's environment" || fail "AGHANIM_* exported: $(cat "$bin/old")"
for lang in en pt-BR; do
  st="$(FACTORY_LANGUAGE=$lang bash "$GATE" stack status 2>/dev/null)"; mapfile -t lines <<< "$st"
  if [ "${#lines[@]}" = 3 ] && [[ "${lines[0]}" =~ ^0${TAB}busy${TAB}validate-1${TAB}[0-9]+${TAB}$ ]] \
     && [[ "${lines[1]}" =~ ^1${TAB}busy${TAB}validate-2${TAB}[0-9]+${TAB}$ ]] && [ "${lines[2]}" = "queue${TAB}0" ]; then
    pass "stack status prints only the TSV, one line per slot, then the queue ($lang)"
  else fail "stack status ($lang): $st"; fi
done
timed up validate-3
{ [ "$T_RC" = 3 ] && [ "$T_SECS" -ge 1 ] && [ "$T_SECS" -le 5 ]; } && pass "a third run waits stack_wait (1 s) on the clock, then exit 3 (${T_SECS}s)" || fail "third run: exit $T_RC after ${T_SECS}s"
assert_contains "$T_ERR" "stack: no free slot after 1s"
[ -z "$(ls "$L/stack-queue")" ] && pass "the run that gave up leaves no ticket" || fail "ticket left: $(ls "$L/stack-queue")"
down validate-1
assert_contains "$(cat "$bin/calls")" "down 0"
[ "$(up validate-3)" = "http://localhost:21000" ] && pass "a released slot lets the next run in" || fail "after the release"
echo "999999 -" > "$L/stack-queue/0000000000000000001-dead"
down validate-3
[ "$(up c)" = "http://localhost:21000" ] && [ ! -e "$L/stack-queue/0000000000000000001-dead" ] && pass "a waiter that died leaves no ticket blocking the queue" || fail "dead ticket: $(ls "$L/stack-queue")"
# a stopped heartbeat makes a slot stuck; the next lease reclaims it and logs why
read -r beat < "$L/stack-1.lock/beat.pid"; kill "$beat" 2>/dev/null; touch -d '-5 minutes' "$L/stack-1.lock/beat"
assert_contains "$(bash "$GATE" stack status)" "stuck${TAB}validate-2"
down c
[ "$(up d)" = "http://localhost:21000" ] && [ "$(up e)" = "http://localhost:21010" ] && pass "the stuck slot is reclaimed by the next lease" || fail "reclaim: $(bash "$GATE" stack status)"
assert_contains "$(cat "$SHIPFLOOR_HOME/logs/stacks.log")" "validate-2 heartbeat"
down d; down e

# ---- health: a body matching stack.reject, a URL that never answers (stack.timeout on the clock), a late healthy stack
echo "Unhandled Runtime Error" > "$bin/health"; : > "$bin/calls"
assert_exit 3 bash "$GATE" stack up validate-6
[ "$(tail -n 1 "$bin/calls")" = "down 0" ] && [ ! -d "$L/stack-0.lock" ] && pass "an unhealthy stack is downed and its slot released" || fail "reject: $(cat "$bin/calls")"
cat > "$bin/hang.py" <<'PY'
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
conns = []
while True:
    c, _ = s.accept(); conns.append(c)
PY
"$FACTORY_PYTHON" "$(nat "$bin")/hang.py" "$(nat "$bin")/port" & PIDS="$PIDS $!"
until_ok 5 test -s "$bin/port"
url="http://127.0.0.1:$(cat "$bin/port")/"
sed -i "s|^  health: .*|  health: \"$url\"|" "$T/s.yml"; : > "$bin/calls"
timed up hang
{ [ "$T_RC" = 3 ] && [ "$T_SECS" -le 5 ]; } && pass "a health URL that never answers gives up after stack.timeout (1 s), not a probe's own 5 s (${T_SECS}s)" || fail "hang: exit $T_RC after ${T_SECS}s"
assert_contains "$T_ERR" "stack: not healthy after 1s at $url"
[ "$(tail -n 1 "$bin/calls")" = "down 0" ] && [ ! -d "$L/stack-0.lock" ] && pass "...then downs the stack and frees the slot" || fail "hang: $(cat "$bin/calls")"
rm -f "$bin/late"; sed -i -e "s|^  health: .*|  health: \"file:///$(nat "$bin")/late\"|" -e 's/^  timeout: 1$/  timeout: 30/' "$T/s.yml"
( sleep 1; echo ok > "$bin/late" ) & PIDS="$PIDS $!"
timed up late
{ [ "$T_RC" = 0 ] && [ "$T_SECS" -le 10 ] && [ "$T_OUT" = "http://localhost:21000" ]; } && pass "a stack healthy before stack.timeout returns its URL at once (${T_SECS}s of 30)" || fail "late: exit $T_RC after ${T_SECS}s: $T_OUT"
down late

# ---- a project with no stack.up (solo) does not shrink the machine's slots for the others
machine 3 22000 3
project "$T/a.yml" solo-a 'stack: {url: "http://localhost:3000"}'
project "$T/b.yml" other-b 'stack:' "  up: 'true'" "  down: 'true'" '  ports: [web]' '  url: "http://localhost:{web}"' '  timeout: 2'
upA() { FACTORY_CONFIG="$T/a.yml" bash "$GATE" stack up "$1"; }
upB() { FACTORY_CONFIG="$T/b.yml" bash "$GATE" stack up "$1"; }
statusA() { FACTORY_CONFIG="$T/a.yml" bash "$GATE" stack status; }
upA a1 >/dev/null
( FACTORY_STACK_WAIT=10 upA a2 > "$bin/a2.out" 2>&1; echo $? > "$bin/a2.rc" ) & A2=$!; until_ok 5 queued a2 || fail "a2 never queued"
st="$(statusA)"
case "$st" in *"0${TAB}busy${TAB}a1"*"1${TAB}free"*"2${TAB}free"*) pass "a second run of A waits while other slots are free" ;; *) fail "solo status: $st" ;; esac
case "$st" in *a2*) fail "the waiting run of A holds a slot: $st" ;; *) pass "...and holds no slot while it waits" ;; esac
out="$(FACTORY_STACK_WAIT=3 upB b1 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "http://localhost:22010" ] && pass "a run of B passes A's waiting run and gets a free slot" || fail "B behind A: exit $rc: $out"
FACTORY_CONFIG="$T/a.yml" bash "$GATE" stack down a1 >/dev/null; wait "$A2"
[ "$(cat "$bin/a2.rc")" = 0 ] && assert_contains "$(cat "$bin/a2.out")" "http://localhost:3000" || fail "a2 exit $(cat "$bin/a2.rc"): $(cat "$bin/a2.out")"
assert_contains "$(statusA)" "busy${TAB}a2"
timed env FACTORY_STACK_WAIT=1 FACTORY_CONFIG="$T/a.yml" bash "$GATE" stack up a3
[ "$T_RC" = 3 ] && [ -z "$(ls "$L/stack-queue")" ] && pass "still waiting after stack_wait: exit 3, no ticket left" || fail "a3: exit $T_RC, queue: $(ls "$L/stack-queue")"
assert_contains "$(statusA)" "2${TAB}free"
# the dead lease sits on slot 1 and slot 0 is B's: with a cap of one slot, the next run of A never looks past slot 0
FACTORY_CONFIG="$T/a.yml" bash "$GATE" stack down a2 >/dev/null; FACTORY_CONFIG="$T/b.yml" bash "$GATE" stack down b1 >/dev/null
upB b2 >/dev/null
mkdir "$L/stack-1.lock"; echo "a-dead $bin/no-such-run $("$REALDATE" +%s)" > "$L/stack-1.lock/info"; echo solo-a > "$L/stack-1.lock/solo"; touch "$L/stack-1.lock/beat"
out="$(FACTORY_STACK_WAIT=2 upA a4 2>&1)"; rc=$?
[ "$rc" = 0 ] && assert_contains "$(statusA)" "1${TAB}busy${TAB}a4" || fail "dead A lease: exit $rc: $out"
assert_contains "$(cat "$SHIPFLOOR_HOME/logs/stacks.log")" "reclaimed slot 1 from a-dead"
[ "$(statusA | cut -f1 | paste -sd, -)" = "0,1,2,queue" ] && pass "stack status lists one line per machine slot, then the queue line" || fail "rows: $(statusA)"

# ---- gates on a needs_stack layer: served in arrival order; INT while running or TERM while waiting gives the slot or
# the ticket back with exit 3 and the INFRA verdict; each keeps its own verdict. Each runner holds its slot until the
# test lets it go (a go-<name> file), so who runs when is decided by the test, not by timing.
machine 3 26500 120
project "$T/f.yml" shop 'stack:' "  up: 'true'" "  down: 'true'" '  ports: [web]' '  url: "http://localhost:{web}"'
export FACTORY_CONFIG="$T/f.yml"
cat > "$bin/pnpm" <<EOF
#!/usr/bin/env bash
sel="\${4:-}"; echo "\$sel slot=\$SHIPFLOOR_SLOT" >> "$T/started"
n=0; while [ ! -e "$T/go-\$sel" ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n+1)); done
[ "\$sel" = g3 ] && { echo "  1 failed"; exit 1; }
echo "  1 passed"
EOF
chmod +x "$bin/pnpm"; export FACTORY_PNPM="$bin/pnpm"
spawn() {  # spawn <name>: a gate in the background with INT and TERM at their default (plain `&` in a script ignores INT)
  "$FACTORY_PYTHON" -I -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGTERM, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$GATE" green e2e "$1" > "$T/$1.out" 2> "$T/$1.err" &
  eval "P_$1=$!"; PIDS="$PIDS $!"
}
started() { grep -q "^$1 " "$T/started" 2>/dev/null; }
has_ticket() { ls "$L/stack-queue" 2>/dev/null | grep -q -- "-gate-$1\$"; }
gone() { ! kill -0 "$1" 2>/dev/null; }
order() { cut -d' ' -f1 "$T/started" 2>/dev/null | tr '\n' ' '; }
verdict() { tail -1 "$T/$1.err"; }
for g in g1 g2 g3; do spawn "$g"; until_ok 20 started "$g" || fail "$g never started"; done
for g in g4 g5 g6; do spawn "$g"; eval "until_ok 20 has_ticket \$P_$g" || fail "$g never queued"; done
[ "$(order)" = "g1 g2 g3 " ] && pass "three gates run on the three slots, the others wait" || fail "started: $(order)"
kill -TERM "$P_g6"
until_ok 5 gone "$P_g6"; wait "$P_g6" 2>/dev/null; rc=$?
[ "$rc" = 3 ] && [ "$(verdict g6)" = "gate green: INFRA (exit 3)" ] && ! has_ticket "$P_g6" && pass "a waiting gate stops on TERM: exit 3, the INFRA verdict, its ticket gone" || fail "g6: exit $rc: $(verdict g6)"
touch "$T/go-g1"; until_ok 20 started g4 || fail "g4 never started after g1 ended"
started g5 && fail "g5 started before its turn" || pass "the slot g1 gave back goes to g4, the first waiter"
kill -INT "$P_g2"
until_ok 5 gone "$P_g2"; wait "$P_g2" 2>/dev/null; rc=$?
[ "$rc" = 3 ] && [ "$(verdict g2)" = "gate green: INFRA (exit 3)" ] && pass "a running gate stops on INT: exit 3 and the INFRA verdict" || fail "g2: exit $rc: $(verdict g2)"
touch "$T/go-g2"
until_ok 20 started g5 && [ "$(order)" = "g1 g2 g3 g4 g5 " ] && pass "the slot g2 gave back goes to g5: arrival order" || fail "order: $(order)"
touch "$T/go-g3" "$T/go-g4" "$T/go-g5"
for g in g1 g3 g4 g5; do eval "wait \$P_$g 2>/dev/null"; eval "rc_$g=$?"; done
[ "$rc_g1 $rc_g3 $rc_g4 $rc_g5" = "0 1 0 0" ] && [ "$(verdict g1)" = "gate green: pass" ] && [ "$(verdict g3)" = "gate green: FAIL (exit 1)" ] \
  && pass "each gate keeps its own verdict (g3's runner failed) and says it last" || fail "g1 g3 g4 g5: $rc_g1 $rc_g3 $rc_g4 $rc_g5 / $(verdict g1) / $(verdict g3)"
st="$(bash "$GATE" stack status)"
[ "$(printf '%s\n' "$st" | grep -c "${TAB}free${TAB}")" = 3 ] && printf '%s\n' "$st" | grep -qx "queue${TAB}0" \
  && pass "afterwards no slot is leased and the queue is empty" || fail "status: $(printf '%s' "$st" | tr '\n' ' ')"

# ---- stack up returns to a `$(...)` caller at once in any language: the heartbeat never holds the caller's pipe
machine 2 22000 10
project "$T/l.yml" shop 'stack:' "  up: 'true'" "  down: 'true'" '  ports: [web, api]' '  url: "http://localhost:{web}"'
for lang in en pt-BR; do
  sed -i '/^language:/d' "$T/l.yml"; echo "language: $lang" >> "$T/l.yml"
  timed timeout 12 env FACTORY_CONFIG="$T/l.yml" bash -c 'url=$(bash "$1" stack up x); echo "$url"' _ "$GATE"
  { [ "$T_RC" = 0 ] && [ "$T_SECS" -lt 5 ] && [ "$T_OUT" = "http://localhost:22000" ]; } && pass "language $lang: a \$(...) caller gets the URL in ${T_SECS}s" || fail "$lang: exit $T_RC after ${T_SECS}s (124 = the \$(...) never closed): $T_OUT"
  FACTORY_CONFIG="$T/l.yml" bash "$GATE" stack down x >/dev/null
done
finish
