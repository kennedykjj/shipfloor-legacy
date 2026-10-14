#!/usr/bin/env bash
# suite: integration
# Stack slots through real processes, where the process is the behavior (the logic is tested in process:
# py/deploy_stack.py): the lib/stack.sh shim and its shell variables, gate.sh / sf.py stack (usage, status, up, down),
# the detached heartbeat of a lease, and one real queue served in arrival order. lsof is a stub throughout.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; for f in "$SHIPFLOOR_HOME"/locks/stack-queue/*; do [ -f "$f" ] && read -r p _ < "$f" && kill -9 "$p" 2>/dev/null; done; kill $(jobs -p) 2>/dev/null; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"; SF="$FACTORY_DIR/sf.py"; L="$SHIPFLOOR_HOME/locks"; Q="$L/stack-queue"
stubs="$T/stubs"; mkdir -p "$stubs"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"; chmod +x "$stubs/lsof"
export PATH="$stubs:$PATH"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
machine() { printf 'stacks: %s\nports: {base: 26300, span: 10}\nstack_wait: %s\nstack_stale: 90\nstack_hold_max: 2700\n' "$1" "$2" > "$SHIPFLOOR_HOME/config.yml"; }
cfg="$T/factory.yml"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
{ echo "stack:"
  echo "  up: 'echo \"up \$SHIPFLOOR_SLOT\" >> \"$T/calls\"'"
  echo "  down: 'echo \"down \$SHIPFLOOR_SLOT\" >> \"$T/calls\"'"
  echo "  ports: [web, api]"
  echo '  url: "http://localhost:{web}/app"'
  echo "  health: \"file:///$(nat "$T")/health\""
  echo "  timeout: 2"; } >> "$cfg"
echo ok > "$T/health"; export FACTORY_CONFIG="$cfg"
until_ok() { local n=$(( $1 * 10 )) i; shift; for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
gone() { ! kill -0 "$1" 2>/dev/null; }
r="$(new_repo)"; cd "$r" || exit 1

# ---- sf.py stack and gate.sh stack: usage, up, status, down
out="$("$FACTORY_PYTHON" -I "$SF" stack 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && case "$out" in "usage: sf.py stack "*) true ;; *) false ;; esac && pass "sf.py stack with no command: usage, exit 2" || fail "sf.py stack: exit $rc: $out"
machine 2 1
url="$(bash "$GATE" stack up one)"; rc=$?
[ "$rc" = 0 ] && [ "$url" = "http://localhost:26300/app" ] && pass "gate.sh stack up: exit 0, the URL on stdout" || fail "stack up: exit $rc, '$url'"
want="$(bash "$GATE" stack status)"; got="$("$FACTORY_PYTHON" -I "$SF" stack status)"
printf '%s\n' "$got" | grep -qxE '0	busy	one	[0-9]+	' && printf '%s\n' "$got" | grep -qx '1	free	-	0	' && printf '%s\n' "$got" | grep -qx 'queue	0' \
  && pass "sf.py stack status: <k> <state> <owner> <held_s> <reason> per slot, then queue <n>" || fail "status: $got"
[ "$(printf '%s\n' "$want" | cut -f1-3)" = "$(printf '%s\n' "$got" | cut -f1-3)" ] && pass "gate.sh stack status prints the same TSV" || fail "gate.sh status: $want"
bash "$GATE" stack down one >/dev/null; rc=$?
[ "$rc" = 0 ] && [ ! -d "$L/stack-0.lock" ] && [ "$(cat "$T/calls")" = "$(printf 'down 0\nup 0\ndown 0')" ] \
  && pass "gate.sh stack down: the down command ran, the slot released" || fail "stack down: exit $rc, calls $(cat "$T/calls")"
sed "s|^  up: .*|  up: 'echo boom; exit 1'|" "$cfg" > "$T/fail.yml"
err="$(FACTORY_CONFIG="$T/fail.yml" bash "$GATE" stack up two 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 3 ] && [ "$err" = "$(printf 'stack: up failed:\nboom')" ] && pass "gate.sh stack up with a failing up: exit 3, the message and up.log on stderr" || fail "up failed: exit $rc: $err"
[ ! -d "$L/stack-0.lock" ] && pass "...and the slot is given back" || fail "the slot is still held"

# ---- the lib/stack.sh shim: shell variables in, SLOT and SHIPFLOOR_* out, exit 3
rm -f "$T/calls"
( source "$FACTORY_DIR/lib/project.sh"; source "$FACTORY_DIR/lib/stack.sh"
  stack_settings
  [ "$STACKS|$BASE|$SPAN|$WAIT|$NAME|$PORTS|$URL|$TIMEOUT|$SOLO" = "2|26300|10|1|shop|web
api|http://localhost:{web}/app|2|-" ] && pass "stack_settings sets the shell's variables from the configs" || fail "stack_settings: $STACKS|$BASE|$SPAN|$WAIT|$NAME|$PORTS|$URL|$TIMEOUT|$SOLO"
  NAME=custom; slot_env 1
  [ "$SHIPFLOOR_STACK" = shipfloor-custom-1 ] && [ "$SHIPFLOOR_PORT_API" = 26311 ] && pass "slot_env exports the slot's variables, with the shell's own settings" || fail "slot_env: $SHIPFLOOR_STACK $SHIPFLOOR_PORT_API"
  PORTS="web-app db"; URL="http://h:{web-app}/{db}"; unset SHIPFLOOR_PORT_DB; slot_env 1 2> "$T/e.err"
  [ "$SHIPFLOOR_PORT_DB" = 26311 ] && [ "$SHIPFLOOR_STACK_URL" = http://h:26310/26311 ] && pass "slot_env skips a name that is not an identifier; the next keeps its index" || fail "slot_env: $SHIPFLOOR_PORT_DB $SHIPFLOOR_STACK_URL"
  grep -q 'SHIPFLOOR_PORT_WEB-APP' "$T/e.err" && pass "...and the shell complains about it on stderr" || fail "slot_env stderr: $(cat "$T/e.err")"
  stack_settings; t="$(queue_ticket shim)"
  [ "$(cat "$t")" = "$$ - -" ] && pass "queue_ticket: the ticket names the shell's pid" || fail "ticket: $(cat "$t")"; rm -f "$t"
  stack_lease a; rc=$?; [ "$rc" = 0 ] && [ "$SLOT" = 0 ] && pass "stack_lease sets SLOT" || fail "stack_lease: $rc SLOT=$SLOT"
  stack_lease b >/dev/null; stack_lease c 2> "$T/c.err"; rc=$?
  [ "$rc" = 3 ] && grep -q 'stack: no free slot after 1s' "$T/c.err" && pass "stack_lease gives up with 3 when every slot stays busy" || fail "stack_lease c: $rc $(cat "$T/c.err")"
  slot_release 0; slot_release 1
  url="$(stack_up u; echo "|$SLOT|$SHIPFLOOR_STACK_URL")"
  [ "$url" = "http://localhost:26300/app
|0|http://localhost:26300/app" ] && pass "stack_up prints the URL and exports SLOT and SHIPFLOOR_*" || fail "stack_up: $url"
  stack_down u; [ ! -d "$L/stack-0.lock" ] && pass "stack_down releases the slot" || fail "stack_down left the slot" )

# ---- the heartbeat of a lease: a detached child that outlives the gate, from /, no inherited fd, its own session,
#      HUP ignored; it stops when the lock dir goes or the slot is released (its 15 s beat: in process)
d="$L/stack-0.lock"
bash "$GATE" stack up hb >/dev/null 3>"$T/fd3" 4>"$T/fd4" 7>"$T/fd7" 9>"$T/fd9"; rc=$?
pid="$(cat "$d/beat.pid" 2>/dev/null)"
[ "$rc" = 0 ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && pass "the heartbeat outlives the gate that started it (pid in beat.pid)" || fail "no live heartbeat: exit $rc, beat.pid '$pid'"
if [ -d "/proc/$pid" ]; then
  [ "$(readlink "/proc/$pid/cwd")" = / ] && pass "the heartbeat runs from /" || fail "heartbeat cwd: $(readlink "/proc/$pid/cwd")"
  # a fd Python opens for a moment while it starts is not inherited: wait up to 3 s for the heartbeat to settle
  heart_fds() { ls "/proc/$pid/fd" 2>/dev/null | sort -n | tr '\n' ' '; }
  until_ok 3 test "$(heart_fds)" = "0 1 2 "
  [ "$(heart_fds)" = "0 1 2 " ] && pass "the heartbeat holds no inherited fd (only 0, 1, 2)" || fail "heartbeat fds: $(heart_fds)"
  nul=1; for f in 0 1 2; do [ "$(readlink "/proc/$pid/fd/$f")" = /dev/null ] || nul=0; done
  [ "$nul" = 1 ] && pass "its stdin, stdout and stderr are /dev/null" || fail "heartbeat std streams"
  sid="$(awk '{ sub(/^.*\) /, ""); print $4 }' "/proc/$pid/stat")"
  [ "$sid" = "$pid" ] && pass "the heartbeat leads its own session" || fail "heartbeat session $sid, pid $pid"
fi
kill -HUP "$pid" 2>/dev/null; sleep 0.3
kill -0 "$pid" 2>/dev/null && pass "the heartbeat ignores HUP" || fail "HUP stopped the heartbeat"
bash "$GATE" stack status | grep -q '^0	busy	hb	' && pass "the slot stays busy while it beats" || fail "status: $(bash "$GATE" stack status | tr '\n' ' ')"
rm -rf "$d"
until_ok 5 gone "$pid" && pass "the heartbeat stops once the lock dir is gone" || { fail "the heartbeat still runs after the lock dir went"; kill "$pid" 2>/dev/null; }
[ ! -e "$d" ] && pass "...and does not bring the lock dir back" || fail "the lock dir came back"
bash "$GATE" stack up hb2 >/dev/null; pid2="$(cat "$d/beat.pid" 2>/dev/null)"; bash "$GATE" stack down hb2 >/dev/null
until_ok 3 gone "$pid2" && pass "releasing the slot stops its heartbeat" || { fail "the heartbeat outlived stack down"; kill "$pid2" 2>/dev/null; }

# ---- one real queue: three waiters (names sorting against their arrival) are served in arrival order, each told
#      its position when it starts to wait
machine 1 60; mkdir -p "$T/out"
bash "$GATE" stack up holder >/dev/null
queued() { [ "$(ls "$Q" | wc -l)" -ge "$1" ]; }
n=0; for w in zeta mid alpha; do
  n=$((n+1)); ( bash "$GATE" stack up "$w" > "$T/out/$w" 2> "$T/out/$w.err" ) &
  until_ok 30 queued "$n" || fail "waiter $w never queued"
done
served() { local w; for w in zeta mid alpha; do case " $order " in *" $w "*) continue ;; esac; [ -s "$T/out/$w" ] && { echo "$w"; return 0; }; done; return 1; }
order=""; prev=holder
for i in 1 2 3; do
  bash "$GATE" stack down "$prev" >/dev/null
  until_ok 15 served || break
  prev="$(served)"; order="$order $prev"
done
[ "${order# }" = "zeta mid alpha" ] && pass "a real queue serves its waiters in arrival order" || fail "served in order '${order# }', want 'zeta mid alpha'"
grep -q 'position 1 of 1' "$T/out/zeta.err" && grep -q 'position 3 of 3' "$T/out/alpha.err" && pass "each waiter reports its position in the queue" || fail "positions: $(cat "$T/out/zeta.err" "$T/out/alpha.err")"
bash "$GATE" stack down "$prev" >/dev/null; wait
finish
