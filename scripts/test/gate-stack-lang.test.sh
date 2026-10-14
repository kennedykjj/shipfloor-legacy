#!/usr/bin/env bash
# gate.sh stack up in a non-English project returns to a `$(...)` caller: the heartbeat never holds the caller's pipe.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"
REALDATE="$(command -v date)"
printf 'stacks: 2\nports: {base: 22000, span: 10}\nstack_wait: 10\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
project() {  # project <language>
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
language: $1
CFG
  export FACTORY_CONFIG="$cfg"
}
timed() {  # timed <cmd...>: sets T_OUT, T_RC and T_SECS (whole seconds)
  local s e; s="$("$REALDATE" +%s)"
  T_OUT="$("$@" 2>/dev/null)"; T_RC=$?
  e="$("$REALDATE" +%s)"; T_SECS=$((e - s))
}
# the caller's own command substitution, as a gate's caller writes it; timeout ends it when the pipe is held open
caller() { timeout 12 bash -c 'url=$(bash "$1" stack up x); echo "$url"' _ "$GATE"; }
echo ok > "$bin/health"
r="$(new_repo)"; cd "$r"

# control: English returns at once
project en
timed caller
{ [ "$T_RC" -eq 0 ] && [ "$T_SECS" -lt 5 ]; } && pass "control: language en returns the URL in ${T_SECS}s" || fail "control: en exit $T_RC after ${T_SECS}s"
bash "$GATE" stack down x >/dev/null

# AC-1: pt-BR and a free slot: the URL in under 5 s
project pt-BR
timed caller
[ "$T_RC" -eq 0 ] && pass "AC-1 pt-BR returns (exit 0)" || fail "AC-1 pt-BR exit $T_RC after ${T_SECS}s, want 0 (124 = the \$(...) never closed)"
case "$T_OUT" in *"http://localhost:22000"*) pass "AC-1 pt-BR prints the stack URL" ;; *) fail "AC-1 pt-BR URL missing: '$T_OUT'" ;; esac
[ "$T_SECS" -lt 5 ] && pass "AC-1 pt-BR returned in ${T_SECS}s" || fail "AC-1 pt-BR took ${T_SECS}s, want under 5"
bash "$GATE" stack down x >/dev/null
finish
