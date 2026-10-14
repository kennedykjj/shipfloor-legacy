#!/usr/bin/env bash
# The dispatcher's process model, with real processes (the rest of a run is py/dispatch_launch.py, in process):
#  - dispatch.sh returns while its run lives: the run is its own detached process (another session), whose pid is in
#    the lock's info and starts the agent; it ends on its own, logs == end and removes only its own lock
#  - SIGHUP to the cycle (exit 129) does not stop the run, nor does a HUP sent to the run and its agent
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
MAINPID=$$
TMPS=()
cleanup() {  # every held run is released and every sleeping child killed when the test ends, whatever happened
  [ "$(exec sh -c 'echo $PPID')" = "$MAINPID" ] || return 0
  local t p
  for t in "${TMPS[@]}"; do
    rm -f "$t/hold" "$t/holdboard"
    [ -f "$t/claude.pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$t/claude.pids"
  done
  return 0
}
trap cleanup EXIT

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
alive() { kill -0 "$1" 2>/dev/null; }
ended() { grep -q "== end /sf:develop 54 " "$FACTORY_HOME"/logs/*-54-develop.log 2>/dev/null; }
lock_gone() { [ ! -d "$FACTORY_HOME/locks/develop-54.lock" ]; }
log54() { cat "$FACTORY_HOME"/logs/*-54-develop.log 2>/dev/null; }

fresh() {  # a new home with card 54 in Ready for Dev; the run's agent holds while $T/hold exists
  T="$(mktemp -d)"; TMPS+=("$T"); export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_PROJECT=shop
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Dev") echo 54 ;;
  "eligible Validation")  # asked after develop's launch: the cycle is still running while this waits
    : > "$T/board-asked"
    n=0; while [ -e "$T/holdboard" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done ;;
  "eligible "*) ;;
  *) echo 0 ;;
esac
EOB
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
prompt="$(cat)"
echo "$$" >> "$T/claude.pids"; echo "$PPID" > "$T/parent"; echo "$prompt" >> "$T/claude.calls"
echo "claude: working on $prompt"
n=0; while [ -e "$T/hold" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
echo "claude: finished $prompt"
EOC
  chmod +x "$T/board" "$T/claude"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude"
}

# ---- the run outlives its cycle, detached, and ends on its own
fresh; touch "$T/hold"
mkdir -p "$FACTORY_HOME/locks/refine-77.lock"; echo "$$ $(date +%s) 77" > "$FACTORY_HOME/locks/refine-77.lock/info"  # another card's run
before="$(date +%s)"; bash "$D" >"$T/out" 2>&1; crc=$?
lock="$FACTORY_HOME/locks/develop-54.lock"
t "the cycle returned 0 while the run is not over" test "$crc" = 0
wait_for "the run's agent to start" test -s "$T/parent"
read -r rpid repoch rn rest < "$lock/info"; cpid="$(head -n1 "$T/claude.pids")"
t "info is '<pid> <epoch> 54'" test "$rn" = 54 -a -z "$rest" -a "$repoch" -ge "$before"
t "info's pid is the process that started the agent" test "$rpid" = "$(cat "$T/parent")"
t "after the cycle returned, the run's process and its agent are alive" alive "$rpid"
t "... and claude too" alive "$cpid"
if sid_me="$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')" && [ -n "$sid_me" ]; then
  t "the run is detached: its session is not the cycle's caller's" test -n "$(ps -o sid= -p "$rpid" | tr -d ' ')" -a "$(ps -o sid= -p "$rpid" | tr -d ' ')" != "$sid_me"
else
  pass "the run is detached (no session ids on this OS: skipped)"
fi
t "the agent got the prompt on stdin" grep -qx '/sf:develop 54' "$T/claude.calls"
t "the run's log holds what the agent wrote, and no == end yet" test "$(log54 | grep -c 'claude: working on /sf:develop 54')-$(log54 | grep -c '== end')" = 1-0
t "the start line carries the run's pid" grep -q "== start /sf:develop 54 .* pid=$rpid" <<< "$(log54)"
rm -f "$T/hold"
wait_for "the run to log == end" ended
wait_for "the run to remove its lock" lock_gone
wait_for "the run's process to end" not alive "$rpid"
t "the run ends with == end /sf:develop 54 exit=0, its agent not cut short" test "$(log54 | grep -c -e '== end /sf:develop 54 exit=0 ' -e 'claude: finished')" = 2
t "the run left another card's lock alone" test -d "$FACTORY_HOME/locks/refine-77.lock"

# ---- SIGHUP to the cycle does not stop the run
fresh; touch "$T/hold" "$T/holdboard"
bash "$D" >"$T/out" 2>&1 &
cyc=$!
wait_for "the run's agent to start" test -s "$T/claude.pids"
wait_for "the cycle to go on to the next queue" test -e "$T/board-asked"
read -r rpid _ < "$FACTORY_HOME/locks/develop-54.lock/info"; cpid="$(head -n1 "$T/claude.pids")"
t "before the HUP, the cycle is alive" alive "$cyc"
kill -HUP "$cyc" "$rpid" "$cpid" 2>/dev/null
wait "$cyc"; hrc=$?
t "SIGHUP ends the cycle (exit 129)" test "$hrc" = 129
t "after SIGHUP to the cycle, the run and its agent, the run is alive" alive "$rpid"
t "... and its agent" alive "$cpid"
rm -f "$T/hold" "$T/holdboard"
wait_for "the run to log == end" ended
t "a run that got SIGHUP finished its work and ended with exit=0" test "$(log54 | grep -c -e '== end /sf:develop 54 exit=0 ' -e 'claude: finished')" = 2
wait_for "the run to remove its lock" lock_gone

# ---- a run that ends asks the scheduler for a cycle (dispatcher.wake), after its lock is gone
fresh; touch "$T/hold"
printf '#!/usr/bin/env bash\n[ -d "$FACTORY_HOME/locks/develop-54.lock" ] && echo held >> "$T/woke" || echo "$*" >> "$T/woke"\n' > "$T/wake"
chmod +x "$T/wake"; printf '%s\n' "$T/wake" now please > "$SHIPFLOOR_HOME/dispatcher.wake"
bash "$D" >"$T/out" 2>&1
wait_for "the run's agent to start" test -s "$T/claude.pids"
t "while the run works, nothing asks for a cycle" test ! -e "$T/woke"
rm -f "$T/hold"
wait_for "the run to remove its lock" lock_gone
wait_for "the run to ask for a cycle" test -s "$T/woke"
t "it asked once, with the file's arguments, after its lock was gone" test "$(cat "$T/woke")" = "now please"
finish
