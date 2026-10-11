#!/usr/bin/env bash
# stack_wait and stack.timeout are seconds on the clock, not loop passes: a slow pass never stretches them.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"
REALDATE="$(command -v date)"; PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done' EXIT

machine() {  # machine <stack_wait>
  printf 'stacks: 2\nports: {base: 22000, span: 10}\nstack_wait: %s\nstack_stale: 90\nstack_hold_max: 2700\n' "$1" > "$SHIPFLOOR_HOME/config.yml"
}
project() {  # project <health> <timeout>
  cfg="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
  cat >> "$cfg" <<CFG
stack:
  up: 'echo "up \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  down: 'echo "down \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  ports: [web, api]
  url: "http://localhost:{web}"
  health: "$1"
  reject: "Runtime Error"
  timeout: $2
CFG
  export FACTORY_CONFIG="$cfg"
}
# a date that is slow to answer +%s: one wait pass (slot_state asks once per slot) takes 4 s or more
mkdir -p "$bin/slow"
printf '#!/bin/sh\ncase "$1" in +%%s) sleep 2;; esac\nexec "%s" "$@"\n' "$REALDATE" > "$bin/slow/date"; chmod +x "$bin/slow/date"
down() { bash "$GATE" stack down "$1" >/dev/null; }
# timed <cmd...>: runs it, sets T_OUT, T_ERR, T_RC and T_SECS (whole seconds on date +%s)
timed() {
  local s e; s="$("$REALDATE" +%s)"
  T_OUT="$("$@" 2> "$bin/err")"; T_RC=$?
  e="$("$REALDATE" +%s)"; T_SECS=$((e - s)); T_ERR="$(cat "$bin/err")"
}
up() { bash "$GATE" stack up "$1"; }
slowup() { PATH="$bin/slow:$PATH" bash "$GATE" stack up "$1"; }
busy_all() { up a >/dev/null; up b >/dev/null; }
r="$(new_repo)"; cd "$r"

echo ok > "$bin/health"; project "file:///$(nat "$bin")/health" 2

# AC-1: every slot busy, stack_wait 3: exit 3, message, between 3 and 8 s
machine 3; busy_all
timed up c1
[ "$T_RC" -eq 3 ] && pass "AC-1 exits 3" || fail "AC-1 exit $T_RC, want 3"
case "$T_ERR" in *"stack: no free slot after 3s"*) pass "AC-1 says no free slot after 3s" ;; *) fail "AC-1 message missing: $T_ERR" ;; esac
{ [ "$T_SECS" -ge 3 ] && [ "$T_SECS" -le 8 ]; } && pass "AC-1 gave up after ${T_SECS}s" || fail "AC-1 gave up after ${T_SECS}s, want 3 to 8 (stack_wait 3)"

# AC-2: each wait pass at least 2 s (here 4 s): still gives up within 8 s
timed slowup c2
{ [ "$T_RC" -eq 3 ] && [ "$T_SECS" -le 8 ]; } && pass "AC-2 slow passes still give up within the limit" || fail "AC-2 exit $T_RC after ${T_SECS}s with slow passes, want exit 3 within 8s (stack_wait 3 counted passes, not seconds)"

# AC-7: FACTORY_STACK_WAIT over a larger stack_wait, same slow passes
machine 60
FACTORY_STACK_WAIT=3 timed slowup c7
{ [ "$T_RC" -eq 3 ] && [ "$T_SECS" -le 8 ]; } && pass "AC-7 FACTORY_STACK_WAIT is seconds" || fail "AC-7 exit $T_RC after ${T_SECS}s, want exit 3 within 8s (FACTORY_STACK_WAIT=3 counted passes)"

# AC-6: a slot released while waiting goes to the first waiter, the second gets none
machine 10
( up first > "$bin/first" 2>/dev/null ) & sleep 1
( up second > "$bin/second" 2>/dev/null ) & sleep 1
down a; wait
case "$(cat "$bin/first")" in *"http://localhost:22000"*) pass "AC-6 the first waiter took the released slot" ;; *) fail "AC-6 first waiter got: $(cat "$bin/first")" ;; esac
[ ! -s "$bin/second" ] && pass "AC-6 the later waiter did not jump the queue" || fail "AC-6 second got a slot first: $(cat "$bin/second")"
down first; down b

# AC-3 and AC-4: a health URL that accepts and never answers, stack.timeout 2
cat > "$bin/hang.py" <<'PY'
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
conns = []
while True:
    c, _ = s.accept(); conns.append(c)
PY
"$FACTORY_PYTHON" "$(nat "$bin")/hang.py" "$(nat "$bin")/port" & PIDS="$PIDS $!"
for _ in $(seq 1 50); do [ -s "$bin/port" ] && break; sleep 0.1; done
url="http://127.0.0.1:$(cat "$bin/port")/"
machine 3; project "$url" 2; : > "$bin/calls"
timed up hang
[ "$T_RC" -eq 3 ] && pass "AC-3 exits 3" || fail "AC-3 exit $T_RC, want 3"
case "$T_ERR" in *"stack: not healthy after 2s at $url"*) pass "AC-3 says not healthy after 2s" ;; *) fail "AC-3 message missing: $T_ERR" ;; esac
{ [ "$T_SECS" -ge 2 ] && [ "$T_SECS" -le 7 ]; } && pass "AC-3 gave up after ${T_SECS}s" || fail "AC-3 gave up after ${T_SECS}s, want 2 to 7 (stack.timeout 2; each probe waited its own 5s)"
# AC-4: down ran, the slot is free, and it all happened within the limit
last="$(tail -n 1 "$bin/calls")"   # stack_up also runs down before up, so only a down after the up counts
case "$last" in "down 0") d=1 ;; *) d=0 ;; esac
{ [ "$d" -eq 1 ] && [ ! -d "$L/stack-0.lock" ] && [ "$T_SECS" -le 7 ]; } && pass "AC-4 down ran and the slot is free by the limit" || fail "AC-4 down after up ran=$d (last call: $last), lock kept=$([ -d "$L/stack-0.lock" ] && echo yes || echo no), exited after ${T_SECS}s, want down, free slot, within 7s"

# AC-5: healthy before stack.timeout: exit 0 with the URL, without waiting out the limit
rm -f "$bin/late"; project "file:///$(nat "$bin")/late" 30
( sleep 1; echo ok > "$bin/late" ) & PIDS="$PIDS $!"
timed up late
{ [ "$T_RC" -eq 0 ] && [ "$T_SECS" -le 10 ]; } && pass "AC-5 healthy stack returned after ${T_SECS}s" || fail "AC-5 exit $T_RC after ${T_SECS}s, want exit 0 well under 30s"
case "$T_OUT" in *"http://localhost:22000"*) pass "AC-5 prints the stack URL" ;; *) fail "AC-5 URL missing: $T_OUT" ;; esac
down late
finish
