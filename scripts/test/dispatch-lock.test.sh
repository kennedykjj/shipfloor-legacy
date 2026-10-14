#!/usr/bin/env bash
# #168 AC-2 (and AC-1): the run lock. The cycle creates locks/<stage>-<n>.lock before it starts the run; the run's own
# process writes info = "pid epoch n" and is detached from the cycle (its own session where the OS has one). A count
# keeps a lock younger than FACTORY_LOCK_TTL whatever its pid; past the TTL it keeps it only while the pid is alive and
# removes it otherwise. The epoch comes from info, else from the lock dir's mtime.
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
BASE_CONFIG="$FACTORY_CONFIG"
TMPS=()
cleanup() { local t; for t in "${TMPS[@]}"; do rm -f "$t/hold"; done; return 0; }  # releases every held run
trap cleanup EXIT
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
alive() { kill -0 "$1" 2>/dev/null; }
dead_pid() { sh -c ':' & local p=$!; wait "$p"; echo "$p"; }
ended() { grep -q "== end /sf:$1 $2 " "$FACTORY_HOME"/logs/*-"$2-$1.log" 2>/dev/null; }
lock_gone() { [ ! -d "$FACTORY_HOME/locks/$1.lock" ]; }

fresh() {  # fresh: a new home; Q_REF / Q_DEV queue cards; the run holds while $T/hold exists and says who its parent is
  T="$(mktemp -d)"; TMPS+=("$T"); export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_PROJECT=shop
  unset FACTORY_LOCK_TTL; export Q_REF= Q_DEV=
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks"
  printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Refinement") echo "${Q_REF:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
p="$(cat)"; echo "$PPID" > "$T/parent"; echo "$p" >> "$T/launched"
n=0; while [ -e "$T/hold" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
EOC
  chmod +x "$T/board" "$T/claude"; export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude"
}
lock() {  # lock <name> <info line or "-" for no info> [touch -d date for the dir]
  local d="$FACTORY_HOME/locks/$1.lock"; mkdir -p "$d"
  [ "$2" = - ] || echo "$2" > "$d/info"
  [ -z "${3:-}" ] || touch -d "$3" "$d"
}
launched() { grep -qx "$1" "$T/launched" 2>/dev/null; }

# ---- the run writes info = "<its pid> <epoch> <n>"; that pid is the process that runs the agent, detached from the cycle
fresh; export Q_DEV=54; touch "$T/hold"
before="$(date +%s)"; bash "$D" >"$T/out" 2>&1; crc=$?
l="$FACTORY_HOME/locks/develop-54.lock"
wait_for "the run's agent to start" test -s "$T/parent"
after="$(date +%s)"
read -r rpid repoch rn rest < "$l/info"
t "AC-2 the cycle returned 0 while the run works" test "$crc" = 0
t "AC-2 info has three fields: pid epoch n" test -n "$rn" -a -z "$rest"
t "AC-2 info's card is 54" test "$rn" = 54
t "AC-2 info's epoch is the run's start time" test "$repoch" -ge "$before" -a "$repoch" -le "$after"
t "AC-2 info's pid is the process that started the agent (the agent's parent)" test "$rpid" = "$(cat "$T/parent")"
t "AC-2 ... and it is alive after the cycle returned" alive "$rpid"
if sid_me="$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')" && [ -n "$sid_me" ]; then
  sid_run="$(ps -o sid= -p "$rpid" 2>/dev/null | tr -d ' ')"
  t "AC-1 the run is detached: its session is not the cycle's caller's" test -n "$sid_run" -a "$sid_run" != "$sid_me"
else
  pass "AC-1 the run is detached (no session ids on this OS: skipped)"
fi
rm -f "$T/hold"
wait_for "the run to end" ended develop 54
wait_for "the run's lock to go" lock_gone develop-54

# ---- the TTL: the epoch from info
now="$(date +%s)"; dead="$(dead_pid)"
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 "$dead $(( now - 90 )) 54"
run_dispatch >/dev/null 2>&1
t "AC-2 a lock younger than the TTL (90 of 100 s) with a dead pid is live: no run" not launched '/sf:develop 54'
t "AC-2 ... and it stays" test -d "$FACTORY_HOME/locks/develop-54.lock"
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 "$dead $(( now - 400 )) 54"
run_dispatch >/dev/null 2>&1
t "AC-2 a lock past the TTL with a dead pid is removed and the card starts" launched '/sf:develop 54'
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 "$$ $(( now - 400 )) 54"
run_dispatch >/dev/null 2>&1
t "AC-2 a lock past the TTL whose pid is alive is live: no run" not launched '/sf:develop 54'
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 "nopid $(( now - 400 )) 54"
run_dispatch >/dev/null 2>&1
t "AC-2 a lock past the TTL whose pid is not a number is removed: the card starts" launched '/sf:develop 54'
fresh; export Q_DEV=54; lock develop-54 "$dead $(( now - 10000 )) 54"
run_dispatch >/dev/null 2>&1
t "AC-2 the default TTL is 3 hours: a 10000 s old lock with a dead pid is live" not launched '/sf:develop 54'

# ---- the TTL: no epoch in info, the lock dir's mtime
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 - '-400 seconds'
run_dispatch >/dev/null 2>&1
t "AC-2 a lock with no info, older than the TTL by its mtime, is removed: the card starts" launched '/sf:develop 54'
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 - '-30 seconds'
run_dispatch >/dev/null 2>&1
t "AC-2 a lock with no info, young by its mtime, is live: no run" not launched '/sf:develop 54'
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 "$$" '-400 seconds'
run_dispatch >/dev/null 2>&1
t "AC-2 a pid with no epoch: the mtime ages it, and the live pid keeps it" not launched '/sf:develop 54'
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100; lock develop-54 "$dead" '-400 seconds'
run_dispatch >/dev/null 2>&1
t "AC-2 a dead pid with no epoch, old by its mtime: removed, the card starts" launched '/sf:develop 54'

# ---- the machine-wide count reclaims another project's dead lock too, and keeps a live one
fresh; export FACTORY_LOCK_TTL=100
o="$SHIPFLOOR_HOME/projects/other/locks"; mkdir -p "$o/develop-7.lock" "$o/develop-8.lock"
echo "$dead $(( now - 400 )) 7" > "$o/develop-7.lock/info"; echo "$$ $(( now - 400 )) 8" > "$o/develop-8.lock/info"
run_dispatch >/dev/null 2>&1
t "AC-2 counting the pool removes another project's old dead lock" test ! -d "$o/develop-7.lock"
t "AC-2 ... and keeps its live one" test -d "$o/develop-8.lock"
finish
