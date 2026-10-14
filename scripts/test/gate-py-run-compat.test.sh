#!/usr/bin/env bash
# #166 (PY-13), AC-8: build, red, green and stack are Python (shipfloor_core/gate/run.py, routed by gate/main.py) and
# scripts/lib/gate-run.sh is gone; lib/stack.sh is a shim of Bash functions calling `sf.py stack ...` that dispatch.sh
# still sources for stack_settings and stack_release_run. The existing stack-*.test.sh, gate-*.test.sh and
# dispatch-stack.test.sh pass unedited against it (they run in the suite).
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
shim="$FACTORY_DIR/lib/stack.sh"

# ---- the gate half: run.py does build, red, green and stack; gate-run.sh is gone
[ ! -e "$FACTORY_DIR/lib/gate-run.sh" ] && pass "AC-8 scripts/lib/gate-run.sh no longer exists" || fail "AC-8 scripts/lib/gate-run.sh still exists"
[ -f "$FACTORY_DIR/shipfloor_core/gate/run.py" ] && pass "AC-8 shipfloor_core/gate/run.py exists" || fail "AC-8 no shipfloor_core/gate/run.py"
grep -q 'gate-run' "$FACTORY_DIR/gate.sh" && fail "AC-8 gate.sh still hands gates to lib/gate-run.sh" || pass "AC-8 gate.sh hands no gate to lib/gate-run.sh"
routes="$("$FACTORY_PYTHON" -I -c 'import importlib, sys; sys.path.insert(0, sys.argv[1]); m = importlib.import_module("shipfloor_core.gate.main")
print(" ".join("%s=%s" % (g, m.GATES.get(g, ("-",))[0]) for g in ("build", "red", "green", "stack")))' "$FACTORY_DIR" 2>&1)"
[ "$routes" = "build=run red=run green=run stack=run" ] && pass "AC-8 gate/main.py routes build, red, green and stack to gate/run.py" || fail "AC-8 routes: $routes"
r="$(new_repo)"; cd "$r"
out="$(bash "$FACTORY_DIR/gate.sh" red 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ "$out" = "$(printf 'red: selector required\ngate red: FAIL (exit 2)')" ] && pass "AC-8 gate.sh red with no selector still says so, exit 2" || fail "AC-8 red with no selector: exit $rc: $out"
out="$(bash "$FACTORY_DIR/gate.sh" stack nonsense 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ "$out" = "stack: up <owner> | down <owner> | status" ] && pass "AC-8 gate.sh stack with a bad word: its usage, exit 2, no verdict" || fail "AC-8 stack nonsense: exit $rc: $out"
cd "$T"

# ---- the shim holds no stack logic of its own
code="$(grep -vE '^[[:space:]]*(#|$)' "$shim")"
grep -q 'sf\.py' "$shim" && printf '%s\n' "$code" | grep -qE '(^|[^a-z_])stack([^a-z_-]|$)' \
  && pass "AC-8 lib/stack.sh runs sf.py stack" || fail "AC-8 lib/stack.sh never runs sf.py stack"
logic="$(printf '%s\n' "$code" | grep -nE 'lsof|netstat|tasklist|taskkill|curl |mkdir |rm -rf|sleep |date |while :|kill -0|kill -9|kill "\$pid"' || true)"
[ -z "$logic" ] && pass "AC-8 lib/stack.sh has no slot, queue, port or health logic left (no mkdir, lsof, curl, sleep, kill...)" \
  || fail "AC-8 lib/stack.sh still holds logic:
$logic"
missing=""
for f in stack_settings slot_dir slot_state fill_ports slot_env free_range slot_down slot_release slot_reclaim solo_busy \
         queue_ticket stack_lease stack_up stack_down stack_release_run stack_status; do
  ( source "$FACTORY_DIR/lib/project.sh"; source "$shim"; declare -F "$f" >/dev/null ) || missing="$missing $f"
done
[ -z "$missing" ] && pass "AC-8 the shim keeps every function of lib/stack.sh" || fail "AC-8 functions missing from the shim:$missing"

# ---- dispatch.sh and gate.sh still use it
grep -q 'source "$HERE/lib/stack.sh"' "$FACTORY_DIR/dispatch.sh" && grep -q 'stack_settings; stack_release_run' "$FACTORY_DIR/dispatch.sh" \
  && pass "AC-8 dispatch.sh still sources lib/stack.sh for stack_settings and stack_release_run" || fail "AC-8 dispatch.sh no longer uses lib/stack.sh"
grep -qE '^from \.\. import .*\bstack\b' "$FACTORY_DIR/shipfloor_core/gate/run.py" 2>/dev/null && pass "AC-8 the gate (gate/run.py) uses shipfloor_core.stack directly" || fail "AC-8 gate/run.py does not use shipfloor_core.stack"

# ---- stack_settings sets the variables its callers read; stack_release_run releases the run's slot through them
printf 'stacks: 2\nports: {base: 26300, span: 10}\nstack_wait: 4\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
got="$( source "$FACTORY_DIR/lib/project.sh"; source "$shim"; stack_settings
        printf '%s|' "$STACK_LOCKS" "$STACKS" "$BASE" "$SPAN" "$WAIT" "$STALE" "$HOLD" "$NAME" "$UP" "$DOWN" "$PORTS" "$URL" "$HEALTH" "$REJECT" "$TIMEOUT" "$SOLO" )"
[ "$got" = "$SHIPFLOOR_HOME/locks|2|26300|10|4|90|2700|shop||||http://localhost:3000|||300|shop|" ] \
  && pass "AC-8 stack_settings sets STACK_LOCKS STACKS BASE SPAN WAIT STALE HOLD NAME UP DOWN PORTS URL HEALTH REJECT TIMEOUT SOLO" \
  || fail "AC-8 stack_settings: $got"
mkdir -p "$T/run" "$SHIPFLOOR_HOME/locks/stack-1.lock"; echo "develop-1 $T/run $(date +%s)" > "$SHIPFLOOR_HOME/locks/stack-1.lock/info"
stubs="$T/stubs"; mkdir -p "$stubs"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"; chmod +x "$stubs/lsof"
( PATH="$stubs:$PATH"; source "$FACTORY_DIR/lib/project.sh"; source "$shim"; stack_settings; stack_release_run "$T/run" )
[ ! -d "$SHIPFLOOR_HOME/locks/stack-1.lock" ] && pass "AC-8 stack_settings; stack_release_run (as dispatch.sh calls them) release the run's slot" \
  || fail "AC-8 stack_release_run left the run's slot"
finish
