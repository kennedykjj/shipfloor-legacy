#!/usr/bin/env bash
# #166 (PY-13), AC-2: the heartbeat of a leased slot is a detached child (shipfloor_core/stack.py): it outlives the
# gate that started it, touches beat every 15 s from /, ignores HUP, holds no inherited fd, runs in its own session,
# and stops when the lock dir is gone (or when the slot is released). The /proc checks run where there is a /proc.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
source "$FACTORY_DIR/lib/portable.sh"
GATE="$FACTORY_DIR/gate.sh"; L="$SHIPFLOOR_HOME/locks"; d="$L/stack-0.lock"

stubs="$T/stubs"; mkdir -p "$stubs"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"; chmod +x "$stubs/lsof"
export PATH="$stubs:$PATH"
printf 'stacks: 1\nports: {base: 26200, span: 10}\nstack_wait: 5\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
cfg="$T/factory.yml"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
printf "stack:\n  up: 'true'\n  down: 'true'\n  ports: [web]\n  url: \"http://localhost:{web}\"\n" >> "$cfg"
export FACTORY_CONFIG="$cfg"
r="$(new_repo)"; cd "$r"

until_ok() { local n=$(( $1 * 10 )) i; shift; for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
gone() { ! kill -0 "$1" 2>/dev/null; }
fresh() { [ $(( $(date +%s) - $(mtime "$d/beat") )) -lt 20 ]; }

# a gate with fds 3..9 open leases a slot and exits
bash "$GATE" stack up hb >/dev/null 3>"$T/fd3" 4>"$T/fd4" 7>"$T/fd7" 9>"$T/fd9"; rc=$?
[ "$rc" = 0 ] && pass "AC-2 gate.sh stack up leases a slot" || fail "AC-2 stack up exit $rc"
pid="$(cat "$d/beat.pid" 2>/dev/null)"
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && pass "AC-2 the heartbeat outlives the gate that started it (pid in beat.pid)" || fail "AC-2 no live heartbeat: beat.pid '$pid'"
if [ -d "/proc/$pid" ]; then
  [ "$(readlink "/proc/$pid/cwd")" = / ] && pass "AC-2 the heartbeat runs from /" || fail "AC-2 heartbeat cwd: $(readlink "/proc/$pid/cwd")"
  fds="$(ls "/proc/$pid/fd" | sort -n | tr '\n' ' ')"
  [ "$fds" = "0 1 2 " ] && pass "AC-2 the heartbeat holds no inherited fd (only 0, 1, 2)" || fail "AC-2 heartbeat fds: $fds ($(ls -l "/proc/$pid/fd" | tail -n +2 | sed 's/.*-> //' | tr '\n' ' '))"
  nul=1; for f in 0 1 2; do [ "$(readlink "/proc/$pid/fd/$f")" = /dev/null ] || nul=0; done
  [ "$nul" = 1 ] && pass "AC-2 its stdin, stdout and stderr are /dev/null" || fail "AC-2 heartbeat std streams: $(for f in 0 1 2; do readlink "/proc/$pid/fd/$f"; done | tr '\n' ' ')"
  sid="$(awk '{ sub(/^.*\) /, ""); print $4 }' "/proc/$pid/stat")"
  [ "$sid" = "$pid" ] && pass "AC-2 the heartbeat leads its own session (detached from the gate's terminal and group)" || fail "AC-2 heartbeat session $sid, pid $pid"
fi
kill -HUP "$pid" 2>/dev/null; sleep 0.5
kill -0 "$pid" 2>/dev/null && pass "AC-2 the heartbeat ignores HUP" || fail "AC-2 HUP stopped the heartbeat"
touch -d '-2 minutes' "$d/beat"
until_ok 18 fresh && pass "AC-2 the heartbeat touches beat again within 15 s" || fail "AC-2 beat not touched in 18 s (age $(( $(date +%s) - $(mtime "$d/beat") ))s)"
bash "$GATE" stack status | grep -q '^0	busy	hb	' && pass "AC-2 the slot stays busy while it beats" || fail "AC-2 status: $(bash "$GATE" stack status | tr '\n' ' ')"
rm -rf "$d"
until_ok 17 gone "$pid" && pass "AC-2 the heartbeat stops once the lock dir is gone" || { fail "AC-2 the heartbeat still runs after the lock dir went"; kill "$pid" 2>/dev/null; }
[ ! -e "$d" ] && pass "AC-2 ...and does not bring the lock dir back" || fail "AC-2 the lock dir came back: $(ls "$d")"

bash "$GATE" stack up hb2 >/dev/null; pid2="$(cat "$d/beat.pid" 2>/dev/null)"
bash "$GATE" stack down hb2 >/dev/null
until_ok 3 gone "$pid2" && pass "AC-2 releasing the slot stops its heartbeat" || { fail "AC-2 the heartbeat outlived stack down"; kill "$pid2" 2>/dev/null; }
finish
