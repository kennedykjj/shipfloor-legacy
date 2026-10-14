#!/usr/bin/env bash
# #166 (PY-13), AC-7: with 3 slots, 5 concurrent `gate.sh green` on a needs_stack layer are served in arrival order
# (FIFO), each keeps its own verdict, an interrupted one (INT while it runs, TERM while it waits) exits 3 and gives
# its slot or ticket back, and no slot is left leased afterwards. Each runner holds its slot until the test lets it go
# (a go-<name> file), so who runs when is decided by the test, not by timing.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
PIDS=""
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; touch "$T"/go-g1 "$T"/go-g2 "$T"/go-g3 "$T"/go-g4 "$T"/go-g5; for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"; L="$SHIPFLOOR_HOME/locks"
stubs="$T/stubs"; mkdir -p "$stubs"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"; chmod +x "$stubs/lsof"; export PATH="$stubs:$PATH"
printf 'stacks: 3\nports: {base: 26500, span: 10}\nstack_wait: 120\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
cfg="$T/factory.yml"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
printf "stack:\n  up: 'true'\n  down: 'true'\n  ports: [web]\n  url: \"http://localhost:{web}\"\n" >> "$cfg"
export FACTORY_CONFIG="$cfg"
# the runner (pnpm exec playwright test <name>): says it started on its slot, waits for go-<name>, fails for g3
cat > "$T/pnpm" <<EOF
#!/usr/bin/env bash
sel="\${4:-}"; echo "\$sel slot=\$SHIPFLOOR_SLOT" >> "$T/started"
n=0; while [ ! -e "$T/go-\$sel" ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n+1)); done
[ "\$sel" = g3 ] && { echo "  1 failed"; exit 1; }
echo "  1 passed"
EOF
chmod +x "$T/pnpm"; export FACTORY_PNPM="$T/pnpm"
r="$(new_repo)"; cd "$r"; mkdir -p web

# spawn <name>: a gate in the background with INT and TERM at their default (plain `&` in a script ignores INT)
spawn() {
  "$FACTORY_PYTHON" -I -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGTERM, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$GATE" green e2e "$1" > "$T/$1.out" 2> "$T/$1.err" &
  eval "P_$1=$!"; PIDS="$PIDS $!"
}
until_ok() { local n=$(( $1 * 10 )) i; shift; for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
started() { grep -q "^$1 " "$T/started" 2>/dev/null; }
has_ticket() { ls "$L/stack-queue" 2>/dev/null | grep -q -- "-gate-$1\$"; }
gone() { ! kill -0 "$1" 2>/dev/null; }
order() { cut -d' ' -f1 "$T/started" 2>/dev/null | tr '\n' ' '; }
verdict() { tail -1 "$T/$1.err"; }

# arrivals in order: g1..g3 take the three slots, g4 then g5 queue, g6 queues behind them
for g in g1 g2 g3; do spawn "$g"; until_ok 20 started "$g" || fail "AC-7 $g never started"; done
spawn g4; eval "until_ok 20 has_ticket \$P_g4" || fail "AC-7 g4 never queued"
spawn g5; eval "until_ok 20 has_ticket \$P_g5" || fail "AC-7 g5 never queued"
spawn g6; eval "until_ok 20 has_ticket \$P_g6" || fail "AC-7 g6 never queued"
[ "$(order)" = "g1 g2 g3 " ] && pass "AC-7 three gates run on the three slots, the others wait" || fail "AC-7 started: $(order)"

# g6, waiting, gets TERM: it leaves the queue and exits 3
kill -TERM "$P_g6"
until_ok 5 gone "$P_g6" && pass "AC-7 a waiting gate stops on TERM" || fail "AC-7 g6 still waits 5 s after TERM"
wait "$P_g6" 2>/dev/null; rc=$?
[ "$rc" = 3 ] && pass "AC-7 ...with exit 3" || fail "AC-7 g6 exited $rc, want 3"
[ "$(verdict g6)" = "gate green: INFRA (exit 3)" ] && pass "AC-7 ...and says 'gate green: INFRA (exit 3)'" || fail "AC-7 g6 verdict: $(verdict g6)"
has_ticket "$P_g6" && fail "AC-7 g6's ticket is still in the queue" || pass "AC-7 ...and its ticket is gone"

# g1 ends: g4 (first in the queue) gets its slot, not g5
touch "$T/go-g1"; until_ok 20 started g4 || fail "AC-7 g4 never started after g1 ended"
started g5 && fail "AC-7 g5 started before its turn" || pass "AC-7 the slot g1 gave back goes to g4, the first waiter"
# g2 is interrupted with INT while it runs: its slot goes to g5
kill -INT "$P_g2"
until_ok 5 gone "$P_g2" && pass "AC-7 a running gate stops on INT" || fail "AC-7 g2 still runs 5 s after INT"
wait "$P_g2" 2>/dev/null; rc=$?
[ "$rc" = 3 ] && [ "$(verdict g2)" = "gate green: INFRA (exit 3)" ] && pass "AC-7 ...with exit 3 and the INFRA verdict" || fail "AC-7 g2 exited $rc: $(verdict g2)"
touch "$T/go-g2"  # its runner, if it outlived the gate, ends
until_ok 20 started g5 && pass "AC-7 the slot g2 gave back goes to g5" || fail "AC-7 g5 never started"
[ "$(order)" = "g1 g2 g3 g4 g5 " ] && pass "AC-7 the gates started in arrival order" || fail "AC-7 order: $(order)"

touch "$T/go-g3" "$T/go-g4" "$T/go-g5"
for g in g1 g3 g4 g5; do eval "wait \$P_$g 2>/dev/null"; eval "rc_$g=$?"; done
[ "$rc_g1 $rc_g3 $rc_g4 $rc_g5" = "0 1 0 0" ] && pass "AC-7 each gate keeps its own verdict (g3's runner failed)" || fail "AC-7 exit codes g1 g3 g4 g5: $rc_g1 $rc_g3 $rc_g4 $rc_g5"
[ "$(verdict g1)" = "gate green: pass" ] && [ "$(verdict g3)" = "gate green: FAIL (exit 1)" ] && [ "$(verdict g5)" = "gate green: pass" ] \
  && pass "AC-7 ...and says it last" || fail "AC-7 verdicts: $(verdict g1) / $(verdict g3) / $(verdict g5)"
st="$(bash "$GATE" stack status)"
[ "$(printf '%s\n' "$st" | grep -c '	free	')" = 3 ] && printf '%s\n' "$st" | grep -qx 'queue	0' \
  && pass "AC-7 afterwards no slot is leased and the queue is empty" || fail "AC-7 status: $(printf '%s' "$st" | tr '\n' ' ')"
finish
