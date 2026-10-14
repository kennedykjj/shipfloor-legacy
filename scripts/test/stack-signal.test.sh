#!/usr/bin/env bash
# A signal reaches a gate that waits for a slot or runs on one: the ticket goes, the slot is freed, it exits 3.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"
PIDS=""
trap 'for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; [ -s "$bin/runner.pid" ] && kill -9 "$(cat "$bin/runner.pid")" 2>/dev/null' EXIT
printf 'stacks: 2\nports: {base: 24000, span: 10}\nstack_wait: 60\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
cfg="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
cat >> "$cfg" <<CFG
stack:
  up: 'echo "up \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  down: 'echo "down \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  ports: [web, api]
  url: "http://localhost:{web}"
  health: "file:///$(nat "$bin")/health"
  reject: "Runtime Error"
  timeout: 5
CFG
export FACTORY_CONFIG="$cfg"
echo ok > "$bin/health"
# a runner that stays up long enough for a signal; its pid is kept so the test can stop it
cat > "$bin/pnpm" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$bin/runner.pid"
exec sleep 30
EOF
chmod +x "$bin/pnpm"
export FACTORY_PNPM="$bin/pnpm"
r="$(new_repo)"; cd "$r"; mkdir -p web

# spawn <out> <cmd...>: a background job with INT and TERM at their default (plain `&` in a script ignores INT)
spawn() {
  local out="$1"; shift
  "$FACTORY_PYTHON" -I -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGTERM, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' "$@" > "$out" 2>&1 &
  SPAWNED=$!; PIDS="$PIDS $SPAWNED"
}
# until <seconds> <command...>: retry every 0.1 s
until_ok() { local n=$(( $1 * 10 )) i; shift; for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
gone() { ! kill -0 "$1" 2>/dev/null; }
no_busy() { ! bash "$GATE" stack status | grep -q "busy"; }
has_ticket() { ls "$L/stack-queue" 2>/dev/null | grep -q -- "-gate-$1\$"; }
no_ticket() { ! has_ticket "$1"; }

# AC-4: a needs_stack green is running; TERM frees its slot
spawn "$bin/g4.out" bash "$GATE" green e2e web/e2e/a.spec.ts; g=$SPAWNED
until_ok 20 test -s "$bin/runner.pid" || fail "AC-4 the runner never started"
bash "$GATE" stack status | grep -q busy && pass "AC-4 the running gate holds a slot" || fail "AC-4 no busy slot while the gate runs"
kill -TERM "$g"
until_ok 5 no_busy && pass "AC-4 TERM leaves the slot free" || fail "AC-4 slot still busy 5s after TERM: $(bash "$GATE" stack status | tr '\n' ' ')"
until_ok 5 gone "$g"; kill -9 "$(cat "$bin/runner.pid")" 2>/dev/null
wait "$g" 2>/dev/null; rc=$?
[ "$rc" -eq 3 ] && pass "AC-4 the gate exits 3" || fail "AC-4 the gate exited $rc, want 3"
bash "$GATE" stack down gate-$g >/dev/null; rm -f "$bin/runner.pid"

# AC-5: a gate queued for a slot; INT and TERM each remove its ticket and exit 3
bash "$GATE" stack up a >/dev/null; bash "$GATE" stack up b >/dev/null
for sig in INT TERM; do
  spawn "$bin/g5.out" bash "$GATE" green e2e web/e2e/a.spec.ts; g=$SPAWNED
  until_ok 15 has_ticket "$g" || fail "AC-5/$sig the gate never took a ticket"
  kill -"$sig" "$g"
  until_ok 5 gone "$g" && pass "AC-5/$sig the queued gate stops" || { fail "AC-5/$sig the gate still waits 5s after $sig"; kill -9 "$g" 2>/dev/null; }
  until_ok 1 no_ticket "$g" && pass "AC-5/$sig its ticket is removed" || fail "AC-5/$sig its ticket is still in the queue"
  wait "$g" 2>/dev/null; rc=$?
  [ "$rc" -eq 3 ] && pass "AC-5/$sig it exits 3" || fail "AC-5/$sig it exited $rc, want 3"
done
bash "$GATE" stack down a >/dev/null; bash "$GATE" stack down b >/dev/null
finish
