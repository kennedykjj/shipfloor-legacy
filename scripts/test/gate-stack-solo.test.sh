#!/usr/bin/env bash
# A project that starts no stack of its own (no stack.up) does not shrink the machine's slots for the others.
# Machine stacks: 3; project A has no stack.up, project B has one; both on one SHIPFLOOR_HOME.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"
printf 'stacks: 3\nports: {base: 22000, span: 10}\nstack_wait: 3\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
base="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$base"
cfgA="$(mktemp)"; sed 's/^  name: shop$/  name: solo-a/' "$base" > "$cfgA"
printf 'stack: {url: "http://localhost:3000"}\n' >> "$cfgA"
cfgB="$(mktemp)"; sed 's/^  name: shop$/  name: other-b/' "$base" > "$cfgB"
cat >> "$cfgB" <<EOF
stack:
  up: 'true'
  down: 'true'
  ports: [web]
  url: "http://localhost:{web}"
  timeout: 2
EOF
upA() { FACTORY_CONFIG="$cfgA" bash "$GATE" stack up "$1"; }
upB() { FACTORY_CONFIG="$cfgB" bash "$GATE" stack up "$1"; }
downA() { FACTORY_CONFIG="$cfgA" bash "$GATE" stack down "$1" >/dev/null; }
statusA() { FACTORY_CONFIG="$cfgA" bash "$GATE" stack status; }
reset() { rm -rf "$L"/stack-*.lock "$L/stack-queue"; mkdir -p "$L/stack-queue"; }
r="$(new_repo)"; cd "$r"
A_URL="http://localhost:3000"

# AC-1 (passes today: B has its own stack.up, so it already sees 3 slots): B gets a free slot while A's run holds one
reset
upA a1 >/dev/null
out="$(FACTORY_STACK_WAIT=2 upB b1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "AC-1 a run of B gets a slot while a run of A holds one" || fail "AC-1 B exit $rc: $out"
assert_contains "$out" "http://localhost:22010"
st="$(statusA)"; assert_contains "$st" "0	busy	a1"; assert_contains "$st" "1	busy	b1"; assert_contains "$st" "2	free"

# AC-2: a second run of A waits while other slots are free, and holds no slot while it waits
reset
upA a1 >/dev/null
( FACTORY_STACK_WAIT=4 upA a2 > "$bin/a2.out" 2>&1; echo $? > "$bin/a2.rc" ) & sleep 1
st="$(statusA)"
assert_contains "$st" "0	busy	a1"
assert_contains "$st" "1	free"
assert_contains "$st" "2	free"
[ "$(grep -c 'a2' <<< "$st")" = 0 ] && pass "AC-2 the waiting run of A holds no slot" || fail "AC-2 a2 holds a slot: $st"
! grep -q "$A_URL" "$bin/a2.out" && pass "AC-2 the second run of A did not lease while A's first holds" || fail "AC-2 a2 leased: $(cat "$bin/a2.out")"
wait

# AC-3: a waiting run of A at the head of the queue does not block a ticket of B behind it
reset
upA a1 >/dev/null
( FACTORY_STACK_WAIT=8 upA a2 > "$bin/a2.out" 2>&1 ) & sleep 1
out="$(FACTORY_STACK_WAIT=3 upB b1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "AC-3 B passes the waiting run of A" || fail "AC-3 B exit $rc, waited behind A's second run: $out"
assert_contains "$out" "http://localhost:22010"
wait

# AC-4 (passes today: A's slot 0 is the only one it ever uses): the waiting run gets its lease when the first releases
reset
upA a1 >/dev/null
( FACTORY_STACK_WAIT=10 upA a2 > "$bin/a2.out" 2>&1; echo $? > "$bin/a2.rc" ) & sleep 1
downA a1
wait
[ "$(cat "$bin/a2.rc")" = 0 ] && pass "AC-4 the waiting run got its lease" || fail "AC-4 a2 exit $(cat "$bin/a2.rc"): $(cat "$bin/a2.out")"
assert_contains "$(cat "$bin/a2.out")" "$A_URL"
assert_contains "$(statusA)" "busy	a2"

# AC-5: a run of A that ended without releasing does not make the next run of A wait for the dead one
# (the dead lease sits on slot 1 and slot 0 is B's: with the old cap of 1 slot the next run of A never looks past slot 0)
reset
upB b1 >/dev/null
mkdir "$L/stack-1.lock"; echo "a-dead $bin/no-such-run $(date +%s)" > "$L/stack-1.lock/info"; echo solo-a > "$L/stack-1.lock/solo"; touch "$L/stack-1.lock/beat"
out="$(FACTORY_STACK_WAIT=3 upA a3 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "AC-5 the next run of A leases instead of waiting for the dead one" || fail "AC-5 exit $rc: $out"
assert_contains "$(statusA)" "1	busy	a3"
assert_contains "$(cat "$SHIPFLOOR_HOME/logs/stacks.log")" "reclaimed slot 1 from a-dead"

# AC-6: still waiting after stack_wait: exit 3, the message, no ticket left
# (exit and message hold today; the free slots 1 and 2 being listed afterwards is what needs the fix)
reset
upA a1 >/dev/null
out="$(FACTORY_STACK_WAIT=2 upA a2 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && pass "AC-6 exit 3" || fail "AC-6 exit $rc: $out"
assert_contains "$out" "stack: no free slot after 2s"
[ -z "$(ls "$L/stack-queue")" ] && pass "AC-6 no ticket left in the queue" || fail "AC-6 ticket left: $(ls "$L/stack-queue")"
st="$(statusA)"; assert_contains "$st" "1	free"; assert_contains "$st" "2	free"

# AC-7: gate.sh stack status from A lists one line per machine slot, then the queue line
reset
lines="$(statusA)"
[ "$(wc -l <<< "$lines" | tr -d ' ')" = 4 ] && pass "AC-7 four lines" || fail "AC-7 want 3 slots and the queue line, got: $lines"
[ "$(cut -f1 <<< "$lines" | paste -sd, -)" = "0,1,2,queue" ] && pass "AC-7 slots 0,1,2 then queue" || fail "AC-7 rows: $(cut -f1 <<< "$lines" | paste -sd, -)"
finish
