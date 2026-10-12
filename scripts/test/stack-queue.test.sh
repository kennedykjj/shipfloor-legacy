#!/usr/bin/env bash
# The stack queue serves waiters in arrival order, whatever the platform's `date` can print (#3).
# A `date` stub stands in for the platform: "noN" prints the seconds and a literal N for +%s%N (macOS),
# "ns" prints seconds and a counting nanosecond part (Linux, Git Bash). Seconds are frozen in $stub/secs,
# so "the same second" is exact, not a race against the clock.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"; Q="$L/stack-queue"
printf 'stacks: 1\nports: {base: 22000, span: 10}\nstack_wait: 120\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
cfg="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
cat >> "$cfg" <<EOF
stack:
  up: 'echo "up \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  down: 'echo "down \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  ports: [web]
  url: "http://localhost:{web}"
  health: "file:///$(nat "$bin")/health"
  timeout: 2
EOF
export FACTORY_CONFIG="$cfg"
echo ok > "$bin/health"

stub="$bin/stub"; mkdir -p "$stub" "$bin/out"
real_date="$(command -v date)"
cat > "$stub/date" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "+%s%N" ] && [ -s "$stub/mode" ]; then
  read -r mode < "$stub/mode"; read -r secs < "$stub/secs"
  if [ "\$mode" = noN ]; then echo "\${secs}N"
  else read -r c < "$stub/count"; c=\$(( c + 1 )); echo "\$c" > "$stub/count"; printf '%s%09d\n' "\$secs" "\$c"; fi
else exec "$real_date" "\$@"; fi
EOF
chmod +x "$stub/date"
export PATH="$stub:$PATH"

up() { bash "$GATE" stack up "$1"; }
down() { bash "$GATE" stack down "$1" >/dev/null; }
qcount() { ls "$Q" 2>/dev/null | wc -l | tr -d ' '; }
r="$(new_repo)"; cd "$r"

start_waiter() {  # start_waiter <name>: queue up in the background; stdout and stderr land in $bin/out
  ( up "$1" > "$bin/out/$1" 2> "$bin/out/$1.err" ) &
}
wait_queue() {  # wait_queue <n>: until n tickets are in the queue directory
  local i; for i in $(seq 1 300); do [ "$(qcount)" -ge "$1" ] && return 0; sleep 0.1; done; return 1
}
wait_served() {  # wait_served <order so far> <names...>: the next name whose lease came through, or "none"
  local done_="$1" i n; shift
  for i in $(seq 1 300); do
    for n in "$@"; do case " $done_ " in *" $n "*) continue ;; esac; [ -s "$bin/out/$n" ] && { echo "$n"; return; }; done
    sleep 0.1
  done
  echo none
}
reset_stub() {  # reset_stub <mode> [secs]
  echo "$1" > "$stub/mode"; echo "${2:-1700000000}" > "$stub/secs"; echo 0 > "$stub/count"; rm -rf "$bin/out"; mkdir -p "$bin/out"
}
cleanup() {  # kill waiters still queued, release the slot, wait for the background subshells
  local f pid
  for f in "$Q"/*; do [ -f "$f" ] || continue; read -r pid _ < "$f"; kill -9 "$pid" 2>/dev/null; rm -f "$f"; done
  down holder; for f in "$bin"/out/*; do case "$f" in *.err) ;; *) down "${f##*/}" ;; esac; done
  wait; : > "$stub/mode"
}
scenario() {  # scenario <mode> <seconds step between arrivals> <names in arrival order...>: prints the order served
  local mode="$1" step="$2" name n=0 secs=1700000000 order="" prev=holder got; shift 2
  reset_stub "$mode" "$secs"
  up holder >/dev/null
  for name in "$@"; do
    n=$(( n + 1 )); start_waiter "$name"; wait_queue "$n" || break
    secs=$(( secs + step )); echo "$secs" > "$stub/secs"
  done
  for name in "$@"; do
    down "$prev"; got="$(wait_served "$order" "$@")"; [ "$got" = none ] && break
    order="$order $got"; prev="$got"
  done
  cleanup
  echo "${order# }"
}
check() {  # check <label> <want> <got>
  [ "$2" = "$3" ] && pass "$1" || fail "$1: served in order '${3:-nobody}', want '$2'"
}

# AC-1: no %N, same second, the later arrival's name sorts first: the earlier arrival gets the slot
check "AC-1 same second without %N: the earlier arrival is served first" "zeta alpha" "$(scenario noN 0 zeta alpha)"
# AC-2: no %N, three in the same second, taken in arrival order
check "AC-2 three in one second without %N are served in arrival order" "c b a" "$(scenario noN 0 c b a)"
# AC-3: a date with %N, the AC-1 scenario still serves the earlier arrival
check "AC-3 same second with %N: the earlier arrival is served first" "zeta alpha" "$(scenario ns 0 zeta alpha)"
# AC-4: eleven in one second: the tenth and eleventh come after the ninth, not before the second
names=(); want=""
for i in $(seq 1 11); do n="$(printf 'w%02d' $(( 100 - i )))"; names+=("$n"); want="$want $n"; done
check "AC-4 eleven in one second are served in arrival order, the tenth after the ninth" "${want# }" "$(scenario noN 0 "${names[@]}")"
# AC-5: different seconds, the earlier arrival wins on either kind of date
check "AC-5 different seconds without %N: the earlier arrival is served first" "zeta alpha" "$(scenario noN 1 zeta alpha)"
check "AC-5 different seconds with %N: the earlier arrival is served first" "zeta alpha" "$(scenario ns 1 zeta alpha)"

# AC-6: the first waiter's process ended: the next in arrival order gets the slot
reset_stub ns
up holder >/dev/null
start_waiter gone; wait_queue 1
gone_pid=""; for f in "$Q"/*; do [ -f "$f" ] && read -r gone_pid _ < "$f"; done
start_waiter second; wait_queue 2
start_waiter third; wait_queue 3
kill -9 "$gone_pid" 2>/dev/null
down holder; got="$(wait_served "" second third)"
cleanup
[ "$got" = second ] && pass "AC-6 a gone first waiter is skipped: the next in arrival order is served" \
  || fail "AC-6 a gone first waiter is skipped: served '$got', want 'second'"

# AC-7: no %N, same second: the wait report says position 1 for the earlier, 2 for the later
reset_stub noN
up holder >/dev/null
start_waiter zeta; wait_queue 1
start_waiter alpha; wait_queue 2
for i in $(seq 1 100); do grep -q position "$bin/out/alpha.err" 2>/dev/null && grep -q position "$bin/out/zeta.err" 2>/dev/null && break; sleep 0.1; done
case "$(cat "$bin/out/zeta.err")" in
  *"position 1 of"*) pass "AC-7 the earlier arrival reports position 1" ;;
  *) fail "AC-7 the earlier arrival reports position 1, said: $(cat "$bin/out/zeta.err")" ;;
esac
case "$(cat "$bin/out/alpha.err")" in
  *"position 2 of 2"*) pass "AC-7 the later arrival reports position 2 of 2" ;;
  *) fail "AC-7 the later arrival reports position 2 of 2, said: $(cat "$bin/out/alpha.err")" ;;
esac
cleanup
finish
