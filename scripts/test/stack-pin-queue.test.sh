#!/usr/bin/env bash
# Characterization of lib/stack.sh's queue and of `stack up` / `stack down`: the up.log tail, the waiting message, the
# queue lock, the slot's env file, stack_down beyond STACKS, the fallback to defaults (AC-6 of #158). These pin what
# the Bash code does today, before the Python port: every assertion passes against the current code.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"
source "$FACTORY_DIR/lib/project.sh"
source "$FACTORY_DIR/lib/stack.sh"

L="$STACK_LOCKS"; Q="$L/stack-queue"; calls="$T/calls"
MACHINE='stacks: 2\nports: {base: 25000, span: 10}\nstack_wait: 3\nstack_stale: 90\nstack_hold_max: 2700\n'
printf "$MACHINE" > "$SHIPFLOOR_HOME/config.yml"
FIX="$FACTORY_DIR/test/fixture/factory.yml"
mkcfg() {  # mkcfg <file> <stack lines...>: the fixture with this stack section
  local f="$1"; shift
  sed '/^stack:/d' "$FIX" > "$f"; { echo "stack:"; printf '  %s\n' "$@"; } >> "$f"
}
# lsof that finds nothing: the port clean-up must never touch a real process of this machine
stubs="$T/stubs"; mkdir -p "$stubs"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"; chmod +x "$stubs/lsof"
export PATH="$stubs:$PATH"

reset() { rm -rf "$L"/stack-*.lock "$Q" "$SHIPFLOOR_HOME/logs" "$calls"; mkdir -p "$Q"; }
up() { bash "$GATE" stack up "$1"; }
lines() { printf '%s' "$1" | grep -c . ; }
r="$(new_repo)"; cd "$r"

# ---- AC-6: `up` fails (non-zero): exit 3, the tail of up.log in the message, the slot given back
{ i=1; while [ $i -le 30 ]; do echo "echo line $i"; i=$((i+1)); done; echo "echo boom >&2"; echo "exit 1"; } > "$T/up.sh"
CFG_UPFAIL="$T/upfail.yml"
mkcfg "$CFG_UPFAIL" "up: 'bash $T/up.sh'" "down: 'echo down-ran >> $calls'" "ports: [web]" 'url: "http://localhost:{web}"'
reset
err="$(FACTORY_CONFIG="$CFG_UPFAIL" bash "$GATE" stack up failing 2>&1 >"$T/up.out")"; code=$?
[ "$code" = 3 ] && pass "AC-6 stack up with an up command that fails is exit 3" || fail "AC-6 up failed: exit $code: $err"
want="$({ echo "stack: up failed:"; i=12; while [ $i -le 30 ]; do echo "line $i"; i=$((i+1)); done; echo boom; })"
[ "$err" = "$want" ] && pass "AC-6 stderr is 'stack: up failed:' then the last 20 lines of up.log (line 12 .. boom)" || fail "AC-6 up failed message: $err"
case "$err" in *"line 11"*) fail "AC-6 the message shows more than the last 20 lines" ;; *) pass "AC-6 the message leaves out what is older than the last 20 lines" ;; esac
[ ! -s "$T/up.out" ] && pass "AC-6 a failed up prints no URL" || fail "AC-6 stdout: $(cat "$T/up.out")"
[ "$(cat "$calls" 2>/dev/null)" = "$(printf 'down-ran\ndown-ran')" ] && pass "AC-6 a failed up runs the down command twice: to clear the range before up, and after the failure" || fail "AC-6 down calls: $(cat "$calls" 2>/dev/null)"
[ ! -d "$L/stack-0.lock" ] && pass "AC-6 a failed up gives the slot back" || fail "AC-6 the slot is still held"

# ---- AC-6: a health check that never answers: exit 3 and the same tail
CFG_SICK="$T/sick.yml"
mkcfg "$CFG_SICK" "up: 'echo started'" "down: 'true'" "ports: [web]" 'url: "http://localhost:{web}"' 'health: "file:///no/such/health"' "timeout: 1"
reset
err="$(FACTORY_CONFIG="$CFG_SICK" bash "$GATE" stack up sick 2>&1 >/dev/null)"; code=$?
[ "$code" = 3 ] && pass "AC-6 a stack that is not healthy within stack.timeout is exit 3" || fail "AC-6 not healthy: exit $code: $err"
[ "$(printf '%s' "$err" | sed -n 1p)" = "stack: not healthy after 1s at file:///no/such/health" ] && pass "AC-6 the message names the timeout and the health URL" || fail "AC-6 not healthy message: $err"
[ "$(printf '%s' "$err" | sed -n 2p)" = "started" ] && pass "AC-6 ...followed by the tail of up.log" || fail "AC-6 not healthy tail: $err"
[ ! -d "$L/stack-0.lock" ] && pass "AC-6 an unhealthy stack gives the slot back" || fail "AC-6 the slot is still held"

# ---- the in-process functions use the first project config
CFG_OK="$T/ok.yml"
mkcfg "$CFG_OK" "up: 'true'" "down: 'true'" "ports: [web, api]" 'url: "http://localhost:{web}"' "timeout: 7"
export FACTORY_CONFIG="$CFG_OK"
stack_settings

# ---- AC-6: queue tickets: the next sequence under the lock, the owner in the name, pid / run / solo inside
reset
t1="$(queue_ticket first)"; t2="$(queue_ticket second)"
[ "${t1##*/}" = "0000000000000000001-first" ] && [ "${t2##*/}" = "0000000000000000002-second" ] && pass "AC-6 tickets are named '<19-digit sequence>-<owner>', counting from 1" || fail "AC-6 tickets: $t1 $t2"
[ "$(cat "$t1")" = "$$ - -" ] && pass "AC-6 a ticket holds 'pid run solo' ('-' for no run lock and a project with an up command)" || fail "AC-6 ticket: $(cat "$t1")"
[ ! -d "$Q/.lock" ] && pass "AC-6 the queue lock is given back" || fail "AC-6 the queue lock was left"
echo x > "$Q/0000000000000000009-gap"; echo x > "$Q/junk"
t3="$(queue_ticket third)"
[ "${t3##*/}" = "0000000000000000010-third" ] && pass "AC-6 the next sequence follows the highest in the queue (gaps and names without digits do not matter)" || fail "AC-6 ticket after a gap: $t3"
t4="$(SHIPFLOOR_RUN_LOCK=/some/run queue_ticket fourth)"
[ "$(cat "$t4")" = "$$ /some/run -" ] && pass "AC-6 a ticket holds the run lock of its run" || fail "AC-6 ticket with a run: $(cat "$t4")"
CFG_SOLO="$T/solo.yml"; sed '/^stack:/d' "$FIX" > "$CFG_SOLO"; echo 'stack: {url: "http://localhost:3000"}' >> "$CFG_SOLO"
t5="$(FACTORY_CONFIG="$CFG_SOLO" bash -c 'source "$1/lib/project.sh"; source "$1/lib/stack.sh"; stack_settings; queue_ticket fifth' _ "$FACTORY_DIR")"
[ "$(cut -d' ' -f3 "$t5")" = shop ] && pass "AC-6 a project with no up command puts its name in the ticket (solo)" || fail "AC-6 solo ticket: $(cat "$t5")"

# ---- AC-6: the queue lock is force-broken after 50 tries (sleep stubbed: 50 tries would take 5 s)
reset
sl="$T/sleepstub"; mkdir -p "$sl"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/sleep.log"\n' "$T" > "$sl/sleep"; chmod +x "$sl/sleep"
mkdir "$Q/.lock"
tk="$(PATH="$sl:$PATH" queue_ticket stuck)"
[ "$(grep -c . "$T/sleep.log")" = 50 ] && pass "AC-6 a queue lock nobody frees is waited for 50 tries (50 sleeps)" || fail "AC-6 sleeps: $(grep -c . "$T/sleep.log")"
[ "$(sort -u "$T/sleep.log")" = "0.1" ] && pass "AC-6 each try waits 0.1 s" || fail "AC-6 sleep arguments: $(sort -u "$T/sleep.log")"
[ "${tk##*/}" = "0000000000000000001-stuck" ] && [ -f "$tk" ] && pass "AC-6 after the 50th try the lock is removed and the ticket is taken" || fail "AC-6 ticket after a stuck lock: '$tk'"
[ ! -d "$Q/.lock" ] && pass "AC-6 the forced lock is given back too" || fail "AC-6 the queue lock was left"
rm -f "$T/sleep.log"; mkdir "$Q/.lock"; echo x > "$Q/.lock/held"
( sleep 1; rm -rf "$Q/.lock" ) &
tk="$(queue_ticket patient)"; wait
[ -f "$tk" ] && pass "AC-6 a lock that is freed in time is simply waited for" || fail "AC-6 no ticket after the lock was freed"

# ---- AC-6: `stack: waiting, position i of n` (all slots busy; stack_wait 2 s)
busy_slots() { reset; for k in 0 1; do mkdir -p "$L/stack-$k.lock"; echo "holder$k - $(date +%s)" > "$L/stack-$k.lock/info"; touch "$L/stack-$k.lock/beat"; done; }
printf 'stacks: 2\nports: {base: 25000, span: 10}\nstack_wait: 2\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
busy_slots
err="$( ( stack_settings; stack_lease waiter ) 2>&1 )"; code=$?
want="$(printf 'stack: waiting, position 1 of 1\nstack: no free slot after 2s')"
[ "$err" = "$want" ] && pass "AC-6 a waiter says 'stack: waiting, position 1 of 1' once, then 'stack: no free slot after 2s'" || fail "AC-6 waiting messages: $err"
( stack_settings; stack_lease waiter ) >/dev/null 2>&1; code=$?
[ "$code" = 3 ] && pass "AC-6 giving up after stack_wait is exit 3" || fail "AC-6 stack_lease gave up with $code"
[ -z "$(ls "$Q")" ] && pass "AC-6 a waiter that gave up leaves no ticket" || fail "AC-6 ticket left: $(ls "$Q")"
busy_slots
echo "$$ - -" > "$Q/0000000000000000001-ahead"
err="$( ( stack_settings; stack_lease behind ) 2>&1 >/dev/null )"
[ "$(printf '%s' "$err" | sed -n 1p)" = "stack: waiting, position 2 of 2" ] && pass "AC-6 a waiter behind one other says 'stack: waiting, position 2 of 2'" || fail "AC-6 position: $err"
[ "$(ls "$Q")" = "0000000000000000001-ahead" ] && pass "AC-6 the ticket of whoever is ahead stays when the later waiter gives up" || fail "AC-6 queue after the later waiter: $(ls "$Q")"
printf "$MACHINE" > "$SHIPFLOOR_HOME/config.yml"

# ---- AC-6: the slot's env file, with special characters in the URL
CFG_SPECIAL="$T/special.yml"
mkcfg "$CFG_SPECIAL" "up: 'true'" "down: 'echo down-ran >> $calls'" "ports: [web, api]" 'url: "http://localhost:{web}/?a=1&b=two words&c=%20#frag"'
reset
url="$(FACTORY_CONFIG="$CFG_SPECIAL" bash "$GATE" stack up special)"
want_url="http://localhost:25000/?a=1&b=two words&c=%20#frag"
[ "$url" = "$want_url" ] && pass "AC-6 stack up prints the URL with & ? = % # and spaces as it is" || fail "AC-6 URL: '$url'"
got="$(LC_ALL=C sort "$L/stack-0.lock/env")"
want="$(printf '%s\n' "SHIPFLOOR_PORT_API=25001" "SHIPFLOOR_PORT_WEB=25000" "SHIPFLOOR_SLOT=0" "SHIPFLOOR_STACK=shipfloor-shop-0" "SHIPFLOOR_STACK_URL=$want_url" | LC_ALL=C sort)"
[ "$got" = "$want" ] && pass "AC-6 the slot's env file is NAME=value lines (slot, stack, URL as it is, one port per name), nothing else" || fail "AC-6 env file: $got"
FACTORY_CONFIG="$CFG_SPECIAL" bash "$GATE" stack down special >/dev/null 2>&1
[ "$(cat "$calls" 2>/dev/null)" = "$(printf 'down-ran\ndown-ran')" ] && pass "AC-6 stack down runs the stored down command (after the one before up) although the env file holds such a URL" || fail "AC-6 down calls: $(cat "$calls" 2>/dev/null)"
[ ! -d "$L/stack-0.lock" ] && pass "AC-6 ...and releases the slot" || fail "AC-6 the slot is still held"

# a port name that is not an identifier: its variable is skipped, the others keep their position
out="$( ( stack_settings; PORTS="web-app db"; URL="http://h:{web-app}/{db}"; slot_env 1 2>"$T/e.err"; env | grep -E '^SHIPFLOOR_' | grep -vE '^SHIPFLOOR_(HOME|GATE_FRESH|PY|LIB|CFG)' | LC_ALL=C sort ) )"
want="$(printf '%s\n' "SHIPFLOOR_PORT_DB=25011" "SHIPFLOOR_SLOT=1" "SHIPFLOOR_STACK=shipfloor-shop-1" "SHIPFLOOR_STACK_URL=http://h:25010/25011" | LC_ALL=C sort)"
[ "$out" = "$want" ] && pass "AC-6 slot_env skips a port name that is not an identifier; the next name keeps its index and the URL still gets the port" || fail "AC-6 slot_env: $out"
case "$(cat "$T/e.err")" in *"SHIPFLOOR_PORT_WEB-APP"*) pass "AC-6 ...and the shell complains about it on stderr (in the machine's language)" ;; *) fail "AC-6 slot_env stderr: $(cat "$T/e.err")" ;; esac

# ---- AC-6: stack_down for a slot >= STACKS (the machine config now allows 2 slots; a lease sits in slot 2)
plant() {  # plant <k> <owner> [run]: a busy lease whose down command logs its slot
  local d="$L/stack-$1.lock"; mkdir -p "$d"; echo "$2 ${3:--} $(date +%s)" > "$d/info"; touch "$d/beat"
  printf 'echo "down slot=$SHIPFLOOR_SLOT" >> "%s"' "$calls" > "$d/down"; printf 'SHIPFLOOR_SLOT=%s\n' "$1" > "$d/env"; echo "$T" > "$d/cwd"
}
reset; mkdir -p "$T/run"
plant 1 late; plant 2 late "$T/run"
( stack_down late ); code=$?
[ "$code" = 0 ] && pass "AC-6 stack_down returns 0" || fail "AC-6 stack_down returned $code"
[ ! -d "$L/stack-1.lock" ] && pass "AC-6 stack_down releases the owner's slot below STACKS (control)" || fail "AC-6 slot 1 still held"
[ -d "$L/stack-2.lock" ] && pass "AC-6 stack_down leaves the owner's slot 2 (>= STACKS) held" || fail "AC-6 slot 2 was released"
[ "$(cat "$calls")" = "down slot=1" ] && pass "AC-6 stack_down runs the down command of slot 1 only, not of slot 2" || fail "AC-6 down calls: $(cat "$calls")"
( stack_down nobody ); [ "$?" = 0 ] && [ -d "$L/stack-2.lock" ] && pass "AC-6 stack_down of an owner who holds nothing is a no-op" || fail "AC-6 stack_down nobody"
( stack_release_run "$T/run" )
[ ! -d "$L/stack-2.lock" ] && pass "AC-6 stack_release_run releases the run's slot whatever its number" || fail "AC-6 stack_release_run left slot 2"
[ "$(tail -1 "$calls")" = "down slot=2" ] && pass "AC-6 ...after running its down command" || fail "AC-6 down calls: $(cat "$calls")"

# ---- AC-6: a broken project config falls back to the defaults and solo (pinned as it is today; the owner decides
#      on #158 whether it should fail closed instead)
show() { printf '%s|' "$STACKS" "$BASE" "$SPAN" "$WAIT" "$STALE" "$HOLD" "$NAME" "$UP" "$DOWN" "$PORTS" "$URL" "$HEALTH" "$REJECT" "$TIMEOUT" "$SOLO"; }
got="$( FACTORY_CONFIG="$CFG_OK" bash -c 'source "$1/lib/project.sh"; source "$1/lib/stack.sh"; stack_settings; '"$(declare -f show)"'; show' _ "$FACTORY_DIR" )"
[ "$got" = "$(printf '2|25000|10|3|90|2700|shop|true|true|web\napi|http://localhost:{web}|||7|-|')" ] && pass "AC-6 a valid project config gives its stack settings (control)" || fail "AC-6 valid settings: $got"
defaults="2|25000|10|3|90|2700|project|||||||300|project|"
printf 'layers: not-a-list\nstack: {ports: [Web], up: 1}\n' > "$T/broken1.yml"
printf '::: not [yaml\n' > "$T/broken2.yml"
n=0
for broken in "$T/broken1.yml" "$T/broken2.yml" "$T/missing.yml"; do
  n=$((n+1))
  got="$( FACTORY_CONFIG="$broken" bash -c 'source "$1/lib/project.sh"; source "$1/lib/stack.sh"; stack_settings 2>/dev/null; '"$(declare -f show)"'; show' _ "$FACTORY_DIR" )"
  [ "$got" = "$defaults" ] && pass "AC-6 broken project config #$n: no stack of its own, name 'project', timeout 300, solo 'project'; machine settings kept" || fail "AC-6 broken config #$n: $got"
done
reset
out="$(FACTORY_CONFIG="$T/broken1.yml" bash "$GATE" stack up solo-run 2>/dev/null)"; code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "AC-6 stack up with a broken project config leases a slot and prints an empty URL" || fail "AC-6 broken config up: exit $code, stdout '$out'"
[ "$(cat "$L/stack-0.lock/solo" 2>/dev/null)" = project ] && pass "AC-6 ...as a solo run of the project called 'project'" || fail "AC-6 solo mark: '$(cat "$L/stack-0.lock/solo" 2>/dev/null)'"
FACTORY_CONFIG="$T/broken1.yml" bash "$GATE" stack down solo-run >/dev/null 2>&1
# the machine config is broken too: the built-in defaults
printf 'stacks: many\n' > "$SHIPFLOOR_HOME/config.yml"
got="$( FACTORY_CONFIG="$CFG_OK" bash -c 'source "$1/lib/project.sh"; source "$1/lib/stack.sh"; stack_settings 2>/dev/null; '"$(declare -f show)"'; show' _ "$FACTORY_DIR" )"
[ "$got" = "$(printf '3|20000|20|1800|90|2700|shop|true|true|web\napi|http://localhost:{web}|||7|-|')" ] && pass "AC-6 a broken machine config gives 3 slots, ports from 20000 by 20, wait 1800, stale 90, hold 2700" || fail "AC-6 machine defaults: $got"
got="$( FACTORY_STACK_WAIT=11 FACTORY_CONFIG="$CFG_OK" bash -c 'source "$1/lib/project.sh"; source "$1/lib/stack.sh"; stack_settings 2>/dev/null; echo "$WAIT"' _ "$FACTORY_DIR" )"
[ "$got" = 11 ] && pass "AC-6 FACTORY_STACK_WAIT overrides the wait" || fail "AC-6 FACTORY_STACK_WAIT: $got"
finish
