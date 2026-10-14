#!/usr/bin/env bash
# Characterization of lib/stack.sh's slots: how a stuck lease is recognized and reclaimed, what slot_release keeps,
# what free_range stops (AC-5 of #158). These pin what the Bash code does today, before the Python port: every
# assertion passes against the current code. The functions run in this shell; lsof, kill and the Windows tools are stubs.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T" "${LIBTMP[@]}"' EXIT
source "$FACTORY_DIR/lib/project.sh"
source "$FACTORY_DIR/lib/stack.sh"

L="$STACK_LOCKS"; calls="$T/calls"
printf 'stacks: 1\nports: {base: 24000, span: 10}\nstack_wait: 2\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
cfg="$T/factory.yml"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
cat >> "$cfg" <<EOF
stack:
  up: 'true'
  down: 'true'
  ports: [web, api]
  url: "http://localhost:{web}"
EOF
export FACTORY_CONFIG="$cfg"

# stubs first on PATH: lsof prints $T/lsof.out and logs its arguments; kill (the program xargs starts) logs its own
stubs="$T/stubs"; mkdir -p "$stubs"
cat > "$stubs/lsof" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/lsof.log"; cat "$T/lsof.out" 2>/dev/null
exit 0
EOF
cat > "$stubs/kill" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/kill.log"
EOF
chmod +x "$stubs/lsof" "$stubs/kill"
export PATH="$stubs:$PATH"
stack_settings

reset() { rm -rf "$L"/stack-*.lock "$L/stack-queue" "$SHIPFLOOR_HOME/logs" "$calls" "$T/lsof.log" "$T/kill.log" "$T/lsof.out"; mkdir -p "$L/stack-queue"; }
plant() {  # plant <k> <owner> <run> <epoch>: a lease whose holder sleeps 300 s as its heartbeat (BEATPID); no owner = no info file
  local d="$L/stack-$1.lock"; mkdir -p "$d"
  [ -z "$2" ] || echo "$2 $3 $4" > "$d/info"
  touch "$d/beat"
  printf 'echo "down slot=$SHIPFLOOR_SLOT cwd=$(pwd)" >> "%s"' "$calls" > "$d/down"
  printf 'SHIPFLOOR_SLOT=%s\n' "$1" > "$d/env"; echo "$T" > "$d/cwd"
  sleep 300 & BEATPID=$!; echo "$BEATPID" > "$d/beat.pid"
}
dead() { local rc; kill -0 "$1" 2>/dev/null || return 0; return 1; }
gone() {  # gone <pid>: the process ended (it was our child: reap it)
  wait "$1" 2>/dev/null; local rc=$?; [ "$rc" = 143 ] || [ "$rc" = 127 ]
}
now() { date +%s; }

# ---- AC-5: slot_state names each way a lease is stuck
reset; stack_settings
[ "$(slot_state 0)" = free ] && pass "AC-5 an absent slot is free" || fail "AC-5 slot_state: $(slot_state 0)"
plant 0 owner - "$(now)"
[ "$(slot_state 0)" = busy ] && pass "AC-5 a fresh lease is busy" || fail "AC-5 slot_state: $(slot_state 0)"
kill "$BEATPID"; gone "$BEATPID"
plant 0 owner - "$(( $(now) - 5000 ))"
[ "$(slot_state 0)" = "stuck hold-max" ] && pass "AC-5 a lease older than stack_hold_max with a live beat is 'stuck hold-max'" || fail "AC-5 slot_state: $(slot_state 0)"
kill "$BEATPID"; gone "$BEATPID"
plant 0 owner - "$(now)"; touch -d '-5 minutes' "$L/stack-0.lock/beat"
[ "$(slot_state 0)" = "stuck heartbeat" ] && pass "AC-5 a lease without a run and without a beat for stack_stale is 'stuck heartbeat'" || fail "AC-5 slot_state: $(slot_state 0)"
kill "$BEATPID"; gone "$BEATPID"
plant 0 owner "$T" "$(now)"; touch -d '-5 minutes' "$L/stack-0.lock/beat"
[ "$(slot_state 0)" = busy ] && pass "AC-5 a lease whose run is alive stays busy without a beat" || fail "AC-5 slot_state: $(slot_state 0)"
kill "$BEATPID"; gone "$BEATPID"
plant 0 owner "$T" "$(( $(now) - 5000 ))"
[ "$(slot_state 0)" = "stuck hold-max" ] && pass "AC-5 a lease whose run is alive is still 'stuck hold-max' past stack_hold_max" || fail "AC-5 slot_state: $(slot_state 0)"
kill "$BEATPID"; gone "$BEATPID"

# ---- AC-5: stack_lease reclaims a stuck slot, whatever the reason
reclaim_case() {  # reclaim_case <reason> <owner> <run> <epoch> [beat age to set]: plant, lease, check
  local reason="$1" owner="$2" out line got
  reset; stack_settings
  plant 0 "$owner" "$3" "$4"; [ -z "${5:-}" ] || touch -d "$5" "$L/stack-0.lock/beat"
  got="$(slot_state 0 2>/dev/null)"  # for no-info the shell itself complains about the missing info file
  [ "$got" = "stuck $reason" ] && pass "AC-5 ($reason) the planted slot is 'stuck $reason'" || fail "AC-5 ($reason) slot_state: $got"
  out="$( stack_settings; stack_lease newcomer 2>&1; echo "SLOT=$SLOT" )"
  case "$out" in *"SLOT=0") pass "AC-5 stack_lease reclaims stuck $reason and takes slot 0" ;; *) fail "AC-5 stack_lease ($reason): $out" ;; esac
  read -r who _ < "$L/stack-0.lock/info" 2>/dev/null
  [ "$who" = newcomer ] && pass "AC-5 ($reason) the slot's info names the new owner" || fail "AC-5 ($reason) info owner: '$who'"
  line="$(cat "$SHIPFLOOR_HOME/logs/stacks.log" 2>/dev/null)"
  [[ "$line" =~ ^[0-9T:+Z.,-]+\ reclaimed\ slot\ 0\ from\ ${owner:-\?}\ $reason$ ]] && pass "AC-5 ($reason) stacks.log says 'reclaimed slot 0 from ${owner:-?} $reason'" || fail "AC-5 ($reason) stacks.log: '$line'"
  [ "$(cat "$calls" 2>/dev/null)" = "down slot=0 cwd=$T" ] && pass "AC-5 ($reason) the old lease's own down command ran, in its cwd, with its env" || fail "AC-5 ($reason) down calls: '$(cat "$calls" 2>/dev/null)'"
  case "$(cat "$T/lsof.log" 2>/dev/null)" in *"-iTCP:24000-24009 -sTCP:LISTEN"*) pass "AC-5 ($reason) the slot's port range was freed (24000-24009)" ;; *) fail "AC-5 ($reason) lsof log: $(cat "$T/lsof.log" 2>/dev/null)" ;; esac
  [ ! -e "$L/stack-0.lock/beat.pid" ] && pass "AC-5 ($reason) the old lease's files are gone" || fail "AC-5 ($reason) old beat.pid still there"
  if [ "$reason" = heartbeat ]; then
    kill -0 "$BEATPID" 2>/dev/null && pass "AC-5 (heartbeat) the beat pid of the old lease is not signalled" || fail "AC-5 (heartbeat) the beat pid was killed"
    kill "$BEATPID" 2>/dev/null; gone "$BEATPID"
  else
    gone "$BEATPID" && pass "AC-5 ($reason) the old lease's beat process is stopped" || fail "AC-5 ($reason) the beat process still runs"
    kill "$BEATPID" 2>/dev/null
  fi
}
reclaim_case hold-max olduser - "$(( $(now) - 5000 ))"
reclaim_case no-info "" - -
reclaim_case run-ended gone "$T/no-such-run" "$(now)"
reclaim_case heartbeat quiet - "$(now)" '-5 minutes'

# ---- AC-5: slot_release keeps the beat pid when the reason is heartbeat
reset; stack_settings
plant 0 owner - "$(now)"
slot_release 0
[ ! -d "$L/stack-0.lock" ] && pass "AC-5 slot_release drops the lock" || fail "AC-5 slot_release left the lock"
gone "$BEATPID" && pass "AC-5 slot_release (no reason) stops the heartbeat process" || fail "AC-5 slot_release (no reason) left the heartbeat running"
plant 0 owner - "$(now)"
slot_release 0 heartbeat
[ ! -d "$L/stack-0.lock" ] && pass "AC-5 slot_release with reason heartbeat drops the lock" || fail "AC-5 slot_release heartbeat left the lock"
kill -0 "$BEATPID" 2>/dev/null && pass "AC-5 slot_release with reason heartbeat keeps the beat pid" || fail "AC-5 slot_release heartbeat killed the beat pid"
kill "$BEATPID" 2>/dev/null; gone "$BEATPID"
for reason in hold-max run-ended no-info; do
  plant 0 owner - "$(now)"
  slot_release 0 "$reason"
  gone "$BEATPID" && pass "AC-5 slot_release with reason $reason stops the heartbeat process" || { fail "AC-5 slot_release $reason kept the heartbeat"; kill "$BEATPID" 2>/dev/null; }
done
reset; mkdir -p "$L/stack-0.lock"
slot_release 0; [ ! -d "$L/stack-0.lock" ] && pass "AC-5 slot_release works on a lock with no beat.pid" || fail "AC-5 slot_release left a lock without beat.pid"
slot_release 0; [ "$?" = 0 ] && pass "AC-5 slot_release of a slot that is not there is not an error" || fail "AC-5 slot_release of an absent slot"

# ---- AC-5: free_range with lsof stubbed
reset; stack_settings
printf 'p111\ncnode\np222\nccom.docker.backend\np333\ncdocker-proxy\np444\ncvpnkit-controller\np555\ncpython3\n' > "$T/lsof.out"
free_range 1; rc=$?
[ "$rc" = 0 ] && pass "AC-5 free_range returns 0" || fail "AC-5 free_range returned $rc"
[ "$(cat "$T/lsof.log")" = "-nP -iTCP:24010-24019 -sTCP:LISTEN -Fpc" ] && pass "AC-5 free_range asks lsof for the slot's listening TCP range (slot 1: 24010-24019)" || fail "AC-5 lsof args: $(cat "$T/lsof.log")"
[ "$(cat "$T/kill.log" 2>/dev/null)" = "-9 111 555" ] && pass "AC-5 free_range kills -9 what listens there, sparing com.docker*, docker* and vpnkit*" || fail "AC-5 kill log: '$(cat "$T/kill.log" 2>/dev/null)'"
rm -f "$T/kill.log" "$T/lsof.log"; : > "$T/lsof.out"
free_range 0
[ "$(cat "$T/lsof.log")" = "-nP -iTCP:24000-24009 -sTCP:LISTEN -Fpc" ] && pass "AC-5 free_range slot 0 asks for 24000-24009" || fail "AC-5 lsof args: $(cat "$T/lsof.log")"
[ ! -e "$T/kill.log" ] && pass "AC-5 free_range kills nothing when nothing listens" || fail "AC-5 kill called: $(cat "$T/kill.log")"
rm -f "$T/kill.log"; printf 'p77\ncdockerd\np88\ncvpnkit\n' > "$T/lsof.out"
free_range 0
[ ! -e "$T/kill.log" ] && pass "AC-5 free_range kills nothing when only Docker's own processes listen" || fail "AC-5 kill called: $(cat "$T/kill.log")"

# ---- AC-5: free_range with the Windows tools stubbed (netstat.exe wins over lsof)
win="$T/win"; mkdir -p "$win"
cat > "$win/netstat.exe" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'

Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:24010          0.0.0.0:0              LISTENING       4242
  TCP    0.0.0.0:24011          0.0.0.0:0              LISTENING       4343
  TCP    [::]:24012             [::]:0                 LISTENING       4444
  TCP    127.0.0.1:24013        0.0.0.0:0              LISTENING       4545
  TCP    0.0.0.0:24014          0.0.0.0:0              LISTENING       4646
  TCP    0.0.0.0:24015          0.0.0.0:0              LISTENING       4949
  TCP    0.0.0.0:24100          0.0.0.0:0              LISTENING       4747
  TCP    0.0.0.0:24009          0.0.0.0:0              LISTENING       4848
  TCP    127.0.0.1:24016        127.0.0.1:55000        ESTABLISHED     4141
  TCP    0.0.0.0:24010          0.0.0.0:0              LISTENING       4242
OUT
EOF
cat > "$win/tasklist.exe" <<'EOF'
#!/usr/bin/env bash
pid="${2##* }"
case "$pid" in
  4242) echo '"node.exe","4242","Console","1","40,000 K"' ;;
  4343) echo '"com.docker.backend.exe","4343","Console","1","40,000 K"' ;;
  4444) echo '"vpnkit.exe","4444","Console","1","40,000 K"' ;;
  4545) echo '"wslrelay.exe","4545","Console","1","40,000 K"' ;;
  4646) echo '"docker-proxy.exe","4646","Console","1","40,000 K"' ;;
  4747|4848|4141) echo '"python.exe","'"$pid"'","Console","1","40,000 K"' ;;
  *) ;;
esac
EOF
cat > "$win/taskkill.exe" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/taskkill.log"
EOF
chmod +x "$win/netstat.exe" "$win/tasklist.exe" "$win/taskkill.exe"
rm -f "$T/kill.log" "$T/lsof.log" "$T/taskkill.log"; printf 'p999\ncnode\n' > "$T/lsof.out"
( PATH="$win:$PATH"; free_range 1 )
[ "$(cat "$T/taskkill.log" 2>/dev/null)" = "//PID 4242 //F" ] && pass "AC-5 free_range (netstat.exe) kills the one non-Docker listener in the range, once" || fail "AC-5 taskkill log: '$(cat "$T/taskkill.log" 2>/dev/null)'"
case "$(cat "$T/taskkill.log" 2>/dev/null)" in *4343*|*4444*|*4545*|*4646*) fail "AC-5 free_range killed a Docker process" ;; *) pass "AC-5 free_range spares com.docker*, vpnkit*, wslrelay* and docker* processes" ;; esac
case "$(cat "$T/taskkill.log" 2>/dev/null)" in *4949*) fail "AC-5 free_range killed a pid whose name it could not read" ;; *) pass "AC-5 free_range spares a pid whose name tasklist.exe does not give" ;; esac
case "$(cat "$T/taskkill.log" 2>/dev/null)" in *4747*|*4848*|*4141*) fail "AC-5 free_range killed outside the range or a connection that is not LISTENING" ;; *) pass "AC-5 free_range ignores ports outside the range and connections that are not LISTENING" ;; esac
[ ! -e "$T/lsof.log" ] && [ ! -e "$T/kill.log" ] && pass "AC-5 with netstat.exe present lsof is not used" || fail "AC-5 lsof used beside netstat.exe"
( PATH="$win:$PATH"; free_range 0 ); rc=$?
[ "$rc" = 0 ] && pass "AC-5 free_range (netstat.exe) returns 0 when nothing listens in the range" || fail "AC-5 free_range rc $rc"
finish
