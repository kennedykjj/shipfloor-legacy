#!/usr/bin/env bash
# Each run that needs the stack gets its own slot: port range, compose project, owned by the scripts.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"
printf 'stacks: 2\nports: {base: 21000, span: 10}\nstack_wait: 3\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
cfg="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
cat >> "$cfg" <<EOF
stack:
  up: 'echo "up \$SHIPFLOOR_SLOT \$SHIPFLOOR_STACK \$SHIPFLOOR_PORT_WEB \$SHIPFLOOR_PORT_API" >> "$bin/calls"; echo "old \$AGHANIM_STACK \$AGHANIM_STACK_URL \$AGHANIM_PORT_WEB" >> "$bin/old"'
  down: 'echo "down \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  ports: [web, api]
  url: "http://localhost:{web}"
  health: "file:///$(nat "$bin")/health"
  reject: "Runtime Error"
  timeout: 2
EOF
export FACTORY_CONFIG="$cfg"
echo ok > "$bin/health"
up() { bash "$GATE" stack up "$1"; }
down() { bash "$GATE" stack down "$1" >/dev/null; }
r="$(new_repo)"; cd "$r"

# two leases get different slots, ports and compose projects; up sees the slot's environment
assert_contains "$(up validate-1)" "http://localhost:21000"
assert_contains "$(up validate-2)" "http://localhost:21010"
assert_contains "$(cat "$bin/calls")" "up 0 shipfloor-shop-0 21000 21001"
# card branches cut before the rename read the old names for a while
assert_contains "$(cat "$bin/old")" "old shipfloor-shop-0 http://localhost:21000 21000"
assert_contains "$(cat "$bin/calls")" "up 1 shipfloor-shop-1 21010 21011"
assert_contains "$(bash "$GATE" stack status)" "busy	validate-1"
# a third waits, then gives up after stack_wait with exit 3
assert_exit 3 bash "$GATE" stack up validate-3
# a release lets the next one in; down ran for the released slot
down validate-1
assert_contains "$(cat "$bin/calls")" "down 0"
assert_contains "$(up validate-3)" "http://localhost:21000"
# a stopped heartbeat makes the slot stuck; the next lease reclaims it and logs why
read -r beat < "$L/stack-1.lock/beat.pid"; kill "$beat" 2>/dev/null; touch -d '-5 minutes' "$L/stack-1.lock/beat"
assert_contains "$(bash "$GATE" stack status)" "stuck	validate-2"
down validate-3
assert_contains "$(up validate-4)" "http://localhost:21000"
assert_contains "$(up validate-5)" "http://localhost:21010"
assert_contains "$(cat "$SHIPFLOOR_HOME/logs/stacks.log")" "validate-2 heartbeat"
down validate-4; down validate-5
# a body matching stack.reject is unhealthy: exit 3, down ran, slot released
echo "Unhandled Runtime Error" > "$bin/health"; : > "$bin/calls"
assert_exit 3 bash "$GATE" stack up validate-6
assert_contains "$(cat "$bin/calls")" "down 0"
[ ! -d "$L/stack-0.lock" ] && pass "unhealthy stack released its slot" || fail "slot kept after a failed up"
# waiters take slots in ticket order
echo ok > "$bin/health"
up a >/dev/null; up b >/dev/null
# each waiter is in the queue before the next step: a fixed sleep let "second" take its ticket first on a busy machine
queued() { local i; for i in $(seq 1 150); do ls "$L/stack-queue" 2>/dev/null | grep -q -- "-$1\$" && return 0; sleep 0.1; done; return 1; }
( up first > "$bin/first" ) & queued first || fail "first never took a ticket"
( up second > "$bin/second" 2>/dev/null ) & queued second || fail "second never took a ticket"
down a; wait
assert_contains "$(cat "$bin/first")" "http://localhost:21000"
[ ! -s "$bin/second" ] && pass "the later waiter did not jump the queue" || fail "second got a slot first: $(cat "$bin/second")"
down first; down b
# a waiter that died leaves no ticket blocking the queue
up a >/dev/null; up b >/dev/null
mkdir -p "$L/stack-queue"; echo "999999 -" > "$L/stack-queue/0000000000000000001-dead"
down a
assert_contains "$(up c)" "http://localhost:21000"
[ ! -e "$L/stack-queue/0000000000000000001-dead" ] && pass "dead waiter's ticket dropped" || fail "dead ticket kept"
down b; down c
# a lease whose run is alive stays busy without a heartbeat (the tool may kill the loop)
run="$(mktemp -d)"; SHIPFLOOR_RUN_LOCK="$run" up live >/dev/null
read -r beat < "$L/stack-0.lock/beat.pid"; kill "$beat" 2>/dev/null; touch -d '-5 minutes' "$L/stack-0.lock/beat"
assert_contains "$(bash "$GATE" stack status)" "busy	live"
rm -rf "$run"; assert_contains "$(bash "$GATE" stack status)" "stuck	live"
down live
finish
