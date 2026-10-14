#!/usr/bin/env bash
# #166 (PY-13), AC-1: stack leases and the queue (shipfloor_core/stack.py behind the lib/stack.sh shim). Each scenario runs
# in a fresh Shipfloor home and its record (output, exit codes, the files under locks/ and logs/) is checked. lsof and kill
# are stubs: the port clean-up never touches a real process of this machine. Settings, slot states, port freeing and
# stack up are pinned by stack-pin-slots.test.sh and stack-pin-queue.test.sh.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT

mkdir -p "$T/rec"

out="$("$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" stack 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && case "$out" in *"sf.py stack"*) true ;; *) false ;; esac \
  && pass "AC-1 sf.py stack is registered (usage, exit 2)" || fail "AC-1 sf.py stack: exit $rc: $out"

# ---- stubs (first on PATH): lsof prints $H/lsof.out and logs its arguments, kill logs its own
stubs="$T/stubs"; mkdir -p "$stubs"
printf '#!/usr/bin/env bash\necho "$*" >> "$H/lsof.log"; cat "$H/lsof.out" 2>/dev/null; exit 0\n' > "$stubs/lsof"
printf '#!/usr/bin/env bash\necho "$*" >> "$H/kill.log"\n' > "$stubs/kill"
chmod +x "$stubs"/*
export PATH="$stubs:$PATH"

FIX="$FACTORY_DIR/test/fixture/factory.yml"
mkcfg() {  # mkcfg <file> <stack lines...>: the fixture with this stack section
  local f="$1"; shift
  sed '/^stack:/d' "$FIX" > "$f"; { echo "stack:"; printf '  %s\n' "$@"; } >> "$f"
}
CFG_UP="$T/up.yml"
mkcfg "$CFG_UP" "up: 'echo up-ran >> \"\$H/calls\"'" \
  "down: 'echo \"down slot=\$SHIPFLOOR_SLOT stack=\$SHIPFLOOR_STACK web=\$SHIPFLOOR_PORT_WEB pwd=\$PWD\" >> \"\$H/calls\"'" \
  "ports: [web, api]" 'url: "http://localhost:{web}/x?a=1&b=two words"' "timeout: 5"
CFG_SOLO="$FIX"  # no up command: a solo project called shop
machine() { printf 'stacks: %s\nports: {base: 26000, span: 10}\nstack_wait: %s\nstack_stale: 90\nstack_hold_max: 2700\n' "$1" "$2" > "$SHIPFLOOR_HOME/config.yml"; }
now() { date +%s; }
plant() {  # plant <k> <owner> <run> <epoch>: a lease (no owner: no info file) whose down command logs its slot
  local d="$STACK_LOCKS/stack-$1.lock"; mkdir -p "$d"
  [ -z "$2" ] || echo "$2 $3 $4" > "$d/info"; touch "$d/beat"
  printf 'echo "down slot=$SHIPFLOOR_SLOT pwd=$(pwd)" >> "%s/calls"' "$H" > "$d/down"; printf 'SHIPFLOOR_SLOT=%s\n' "$1" > "$d/env"; echo "$H" > "$d/cwd"
}
dump() {  # every file under locks/ and logs/ with its contents (beat.pid holds a pid: only its presence)
  local f
  (cd "$SHIPFLOOR_HOME" && find locks logs 2>/dev/null | LC_ALL=C sort) | while read -r f; do
    if [ -d "$SHIPFLOOR_HOME/$f" ]; then echo "[$f/]"
    else case "$f" in  # the env file in name order: Bash wrote it in the order of its own variable table
      *beat.pid) echo "[$f] (pid)" ;; */env) echo "[$f]"; LC_ALL=C sort "$SHIPFLOOR_HOME/$f" ;; *) echo "[$f]"; cat "$SHIPFLOOR_HOME/$f"; echo ;; esac; fi
  done
  echo "[calls]"; cat "$H/calls" 2>/dev/null; rm -f "$H/calls"
}
qls() { echo "queue: $(ls "$STACK_LOCKS/stack-queue" | tr '\n' ' ')"; }

# ---- scenarios: each runs in a subshell, in this side's home, with the side's lib/stack.sh sourced
scenario_lease() {
  machine 2 2; export FACTORY_CONFIG="$CFG_UP"; stack_settings; local rc Q="$STACK_LOCKS/stack-queue"
  stack_lease a; rc=$?; echo "lease a: rc=$rc SLOT=$SLOT"
  stack_lease b; rc=$?; echo "lease b: rc=$rc SLOT=$SLOT"
  dump
  ( stack_lease c ) 2>&1; echo "lease c (all busy): rc=$?"; qls
  slot_release 1
  echo "999999999 - -" > "$Q/0000000000000000001-dead"; echo "$$ $H/no-run -" > "$Q/0000000000000000002-ended"
  echo "$$ - -" > "$Q/0000000000000000003-alive"
  ( stack_lease d ) 2>&1; echo "lease d (behind a live ticket): rc=$?"; qls
  rm -f "$Q/0000000000000000003-alive"
  echo shop > "$STACK_LOCKS/stack-0.lock/solo"; echo "$$ - shop" > "$Q/0000000000000000005-solo"
  stack_lease e 2>&1; rc=$?; echo "lease e (ahead: a solo run blocked by its own project): rc=$rc SLOT=$SLOT"; qls
  rm -f "$Q/0000000000000000005-solo"
  printf 'e - %s\n' "$(( $(now) - 5000 ))" > "$STACK_LOCKS/stack-1.lock/info"; echo "$H" > "$STACK_LOCKS/stack-1.lock/cwd"
  printf 'echo "down slot=$SHIPFLOOR_SLOT pwd=$(pwd)" >> "%s/calls"' "$H" > "$STACK_LOCKS/stack-1.lock/down"
  printf 'SHIPFLOOR_SLOT=1\n' > "$STACK_LOCKS/stack-1.lock/env"
  stack_lease f 2>&1; rc=$?; echo "lease f (slot 1 stuck hold-max): rc=$rc SLOT=$SLOT"
  dump
  export FACTORY_CONFIG="$CFG_SOLO"; stack_settings; slot_release 0
  ( SHIPFLOOR_RUN_LOCK="$H/run" stack_lease g0 ) 2>&1; echo "lease g0 (its run lock is gone: its own ticket leaves the queue): rc=$?"
  mkdir -p "$H/run"; SHIPFLOOR_RUN_LOCK="$H/run" stack_lease g; rc=$?; echo "lease g (solo, with a run lock): rc=$rc SLOT=$SLOT"
  t="$(queue_ticket h)"; echo "ticket: ${t##*/}: $(cat "$t")"; rm -f "$t"
  dump
}
scenario_release() {
  machine 3 2; export FACTORY_CONFIG="$CFG_UP"; stack_settings; mkdir -p "$H/run1" "$H/run2"; ln -s "$H/run1" "$H/link"
  plant 0 x "$H/run1" "$(now)"; plant 1 y "$H/link" "$(now)"; plant 2 x "$H/run2" "$(now)"
  stack_release_run "$H/run1"; echo "release_run run1: $?"; dump
  stack_down x; echo "stack_down x: $?"; dump
  stack_down nobody; echo "stack_down nobody: $?"
  plant 0 "" - -; plant 1 z - "$(( $(now) - 5000 ))"
  slot_reclaim 0 no-info; slot_reclaim 1 hold-max; dump
}
scenario_env() {
  machine 2 2; export FACTORY_CONFIG="$CFG_UP"; stack_settings
  slot_env 1; env | grep -E '^SHIPFLOOR_(SLOT|STACK|STACK_URL|PORT_[A-Z0-9_-]+)=' | LC_ALL=C sort
  echo "fill_ports: $(fill_ports 1 'http://h:{web}/{api}/{web}/{db}')"
  PORTS="web-app db"; URL="http://h:{web-app}/{db}"
  slot_env 0 2>"$H/e.err"; env | grep -E '^SHIPFLOOR_(SLOT|STACK|STACK_URL|PORT_[A-Z0-9_-]+)=' | LC_ALL=C sort
  grep -q 'SHIPFLOOR_PORT_WEB-APP' "$H/e.err" && echo "the shell complains about SHIPFLOOR_PORT_WEB-APP"
}

norm() {  # norm <home>: the side's paths, ISO timestamps and epochs written out
  sed -E -e "s|$1|<H>|g" -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)/<TS>/g' \
    -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<E>\2/g' -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<E>\2/g'
}
run_side() {  # run_side <scenario>: its record in $T/rec/<scenario>
  local sc="$1" home="$T/py/$1"
  rm -rf "$home"; mkdir -p "$home/sh" "$home/w"
  ( export SHIPFLOOR_HOME="$home/sh" H="$home"; cd "$home/w" || exit 99
    source "$FACTORY_DIR/lib/project.sh"; source "$FACTORY_DIR/lib/stack.sh"; "scenario_$sc" ) > "$T/rec/$sc.raw" 2>&1
  echo "exit $?" >> "$T/rec/$sc.raw"
  norm "$home" < "$T/rec/$sc.raw" > "$T/rec/$sc"
}
has() {  # has <scenario> <label> <fixed string>: the record holds it
  grep -qF -- "$3" "$T/rec/$1" && pass "AC-1 $2" || fail "AC-1 $2: no '$3' in: $(cat "$T/rec/$1")"
}
for sc in lease release env; do run_side "$sc"; done
has lease "two leases take slots 0 and 1" "lease a: rc=0 SLOT=0
lease b: rc=0 SLOT=1"
has lease "a waiter that gives up says so and exits 3" "stack: no free slot after 2s
lease c (all busy): rc=3"
has lease "dead and ended tickets are dropped; a waiter behind a live one waits at position 2 and leaves its ticket" "stack: waiting, position 2 of 2
stack: no free slot after 2s
lease d (behind a live ticket): rc=3
queue: 0000000000000000003-alive "
has lease "a solo ticket blocked by its own project's slot does not hold the queue" "lease e (ahead: a solo run blocked by its own project): rc=0 SLOT=1"
has lease "a stuck slot is reclaimed, its down command run, and logged" "lease f (slot 1 stuck hold-max): rc=0 SLOT=1"
has lease "... stacks.log names the slot, the owner and the reason" "reclaimed slot 1 from e hold-max"
has lease "a waiter whose run lock is gone gives up (exit 3)" "lease g0 (its run lock is gone: its own ticket leaves the queue): rc=3"
has lease "a solo run with a run lock leases and records the run" "g <H>/run <E>"
has lease "tickets are '<19 digits>-<owner>' holding 'pid run solo'" "ticket: 0000000000000000001-h: "
has release "stack_release_run releases the run's slot, also through a symlinked run path, running each down command" "release_run run1: 0"
has release "... slots 0 (run1) and 1 (a symlink to run1) went down, slot 2 (run2) stays" "[locks/stack-2.lock/info]
x <H>/run2 <E>

[locks/stack-queue/]
[logs/]
[calls]
down slot=0 pwd=<H>
down slot=1 pwd=<H>
stack_down x: 0"
has release "stack_down releases the owner's slot after its down command" "down slot=2 pwd=<H>
stack_down nobody: 0"
has release "slot_reclaim logs a lease with no info as '?'" "reclaimed slot 0 from ? no-info"
has env "fill_ports fills every known port and leaves an unknown name as it is" "fill_ports: http://h:26010/26011/26010/{db}"
has env "slot_env exports the slot, the stack, the URL as it is and one port per name" "SHIPFLOOR_STACK_URL=http://localhost:26010/x?a=1&b=two words"

# ---- sf.py stack status (what the shim runs) prints the TSV gate.sh stack status prints
export FACTORY_CONFIG="$CFG_UP"; machine 2 2; mkdir -p "$SHIPFLOOR_HOME/locks/stack-1.lock"; echo "o - $(now)" > "$SHIPFLOOR_HOME/locks/stack-1.lock/info"
touch "$SHIPFLOOR_HOME/locks/stack-1.lock/beat"
r="$(new_repo)"; cd "$r"
want="$(bash "$FACTORY_DIR/gate.sh" stack status)"; got="$("$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" stack status 2>&1)"
held10() { awk -F'\t' -v OFS='\t' '$1 != "queue" { $4 = int(($4 + 5) / 10) * 10 } { print }'; }  # the two run a second apart
[ "$(printf '%s\n' "$got" | held10)" = "$(printf '%s\n' "$want" | held10)" ] && [ -n "$want" ] && pass "AC-1 sf.py stack status prints the TSV of gate.sh stack status" || fail "AC-1 sf.py stack status: '$got', want '$want'"
printf '%s\n' "$got" | grep -qxE '1	busy	o	[0-9]+	' && printf '%s\n' "$got" | grep -qx 'queue	0' \
  && pass "AC-1 the TSV is <k> <state> <owner> <held_s> <reason>, then queue <n>" || fail "AC-1 TSV shape: $got"
finish
