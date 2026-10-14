#!/usr/bin/env bash
# #166 (PY-13), AC-1: stack state, lease and queue, ported to shipfloor_core/stack.py behind the lib/stack.sh shim,
# behave as the Bash lib/stack.sh kept as test/fixtures/stack.bash.sh. Each scenario runs twice, each time in a fresh
# Shipfloor home: on the fixture, then on the shim. The records (output, exit codes, the files under locks/ and logs/)
# must match once epochs, timestamps and the side's own paths are written out. lsof and kill are stubs: the port
# clean-up never touches a real process of this machine.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT

FIXLIB="$T/fixture-lib"; mkdir -p "$FIXLIB" "$T/rec"
cp "$FACTORY_DIR/test/fixtures/stack.bash.sh" "$FIXLIB/stack.sh" 2>/dev/null; cp "$FACTORY_DIR/test/fixtures/portable.sh" "$FIXLIB/"

# ---- the port is in place
[ -f "$FACTORY_DIR/test/fixtures/stack.bash.sh" ] && grep -q 'mkdir "$(slot_dir "$k")"' "$FACTORY_DIR/test/fixtures/stack.bash.sh" \
  && pass "AC-1 the Bash lib/stack.sh is kept as test/fixtures/stack.bash.sh" || fail "AC-1 no Bash fixture test/fixtures/stack.bash.sh"
[ -f "$FACTORY_DIR/shipfloor_core/stack.py" ] && pass "AC-1 shipfloor_core/stack.py exists" || fail "AC-1 no shipfloor_core/stack.py"
out="$("$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" stack 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && case "$out" in *"sf.py stack"*) true ;; *) false ;; esac \
  && pass "AC-1 sf.py stack is registered (usage, exit 2)" || fail "AC-1 sf.py stack: exit $rc: $out"

# ---- stubs (first on PATH): lsof prints $H/lsof.out and logs its arguments, kill logs its own, the Windows tools too
stubs="$T/stubs"; win="$T/win"; mkdir -p "$stubs" "$win"
printf '#!/usr/bin/env bash\necho "$*" >> "$H/lsof.log"; cat "$H/lsof.out" 2>/dev/null; exit 0\n' > "$stubs/lsof"
printf '#!/usr/bin/env bash\necho "$*" >> "$H/kill.log"\n' > "$stubs/kill"
cat > "$win/netstat.exe" <<'EOF'
#!/usr/bin/env bash
printf '  Proto  Local Address  Foreign Address  State  PID\n'
printf '  TCP    0.0.0.0:26010  0.0.0.0:0  LISTENING  4242\n  TCP    [::]:26011  [::]:0  LISTENING  4343\n'
printf '  TCP    0.0.0.0:26012  0.0.0.0:0  LISTENING  4949\n  TCP    0.0.0.0:26020  0.0.0.0:0  LISTENING  4747\n'
printf '  TCP    127.0.0.1:26013  127.0.0.1:5  ESTABLISHED  4141\n  TCP    0.0.0.0:26014  0.0.0.0:0  LISTENING  4242\n'
EOF
cat > "$win/tasklist.exe" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$H/tasklist.log"
case "${2##* }" in 4242) echo '"node.exe","4242","Console","1","4 K"' ;; 4343) echo '"com.docker.backend.exe","4343"' ;; 4747) echo '"python.exe","4747"' ;; esac
EOF
printf '#!/usr/bin/env bash\necho "$*" >> "$H/taskkill.log"\n' > "$win/taskkill.exe"
chmod +x "$stubs"/* "$win"/*
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
printf 'layers: not-a-list\nstack: {ports: [Web], up: 1}\n' > "$T/broken.yml"
machine() { printf 'stacks: %s\nports: {base: 26000, span: 10}\nstack_wait: %s\nstack_stale: 90\nstack_hold_max: 2700\n' "$1" "$2" > "$SHIPFLOOR_HOME/config.yml"; }
now() { date +%s; }
plant() {  # plant <k> <owner> <run> <epoch>: a lease (no owner: no info file) whose down command logs its slot
  local d="$STACK_LOCKS/stack-$1.lock"; mkdir -p "$d"
  [ -z "$2" ] || echo "$2 $3 $4" > "$d/info"; touch "$d/beat"
  printf 'echo "down slot=$SHIPFLOOR_SLOT pwd=$(pwd)" >> "%s/calls"' "$H" > "$d/down"; printf 'SHIPFLOOR_SLOT=%s\n' "$1" > "$d/env"; echo "$H" > "$d/cwd"
}
show() { printf '%s|' "$STACKS" "$BASE" "$SPAN" "$WAIT" "$STALE" "$HOLD" "$NAME" "$UP" "$DOWN" "$PORTS" "$URL" "$HEALTH" "$REJECT" "$TIMEOUT" "$SOLO"; echo; }
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
scenario_settings() {
  machine 2 3
  export FACTORY_CONFIG="$CFG_UP"; stack_settings; show
  export FACTORY_CONFIG="$CFG_SOLO"; stack_settings; show
  export FACTORY_CONFIG="$T/broken.yml"; stack_settings 2>/dev/null; show
  export FACTORY_CONFIG="$T/missing.yml"; stack_settings 2>/dev/null; show
  export FACTORY_CONFIG="$CFG_UP"; FACTORY_STACK_WAIT=9 stack_settings; show
  printf 'stacks: many\n' > "$SHIPFLOOR_HOME/config.yml"; stack_settings 2>/dev/null; show
  dump
}
scenario_state() {
  machine 8 3; export FACTORY_CONFIG="$CFG_UP"; stack_settings; mkdir -p "$H/run"
  plant 1 o1 - "$(now)"
  plant 2 o2 - "$(( $(now) - 5000 ))"
  plant 3 o3 - "$(now)"; touch -d '-5 minutes' "$STACK_LOCKS/stack-3.lock/beat"
  plant 4 o4 "$H/no-run" "$(now)"
  plant 5 o5 "$H/run" "$(now)"; touch -d '-5 minutes' "$STACK_LOCKS/stack-5.lock/beat"
  plant 6 "" - -
  plant 7 o7 - -; printf 'o7 - %s' "$(now)" > "$STACK_LOCKS/stack-7.lock/info"
  local k; for k in 0 1 2 3 4 5 6 7 8; do echo "slot_state $k: $(slot_state "$k" 2>/dev/null)"; done
  echo "$$ - -" > "$STACK_LOCKS/stack-queue/0000000000000000001-a"; echo "$$ - -" > "$STACK_LOCKS/stack-queue/0000000000000000002-b"
  mkdir -p "$STACK_LOCKS/stack-queue/.lock"
  # held_s to the nearest 10 s: the two sides run a second apart
  stack_status 2>/dev/null | awk -F'\t' -v OFS='\t' '$1 != "queue" { $4 = int(($4 + 5) / 10) * 10 } { print }'
  rmdir "$STACK_LOCKS/stack-queue/.lock"
  solo_busy shop; echo "solo_busy shop (none): $?"
  echo shop > "$STACK_LOCKS/stack-1.lock/solo"; solo_busy shop; echo "solo_busy shop (busy slot 1): $?"
  echo shop > "$STACK_LOCKS/stack-2.lock/solo"; rm "$STACK_LOCKS/stack-1.lock/solo"; solo_busy shop; echo "solo_busy shop (stuck slot 2): $?"
}
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
scenario_up() {
  machine 1 1; export FACTORY_CONFIG="$CFG_UP"; local rc
  stack_up u1 > "$H/url"; rc=$?; echo "stack_up u1: rc=$rc SLOT=$SLOT url=$(cat "$H/url")"
  env | grep -E '^SHIPFLOOR_(SLOT|STACK|STACK_URL|PORT_[A-Z0-9]+)=' | LC_ALL=C sort
  dump
  ( stack_up u2 ) 2>&1; echo "stack_up u2 (no slot): rc=$?"
  stack_down u1; echo "stack_down u1: $?"; dump
  export FACTORY_CONFIG="$CFG_SOLO"; stack_up s1; echo "stack_up s1 (solo): rc=$?"; dump; stack_down s1
}
scenario_free() {
  machine 2 2; export FACTORY_CONFIG="$CFG_UP"; stack_settings
  printf 'p111\ncnode\np222\nccom.docker.backend\np333\ncdocker-proxy\np444\ncvpnkit\np555\ncpython3\n' > "$H/lsof.out"
  free_range 1; echo "free_range 1: $?"; echo "lsof: $(cat "$H/lsof.log")"; echo "kill: $(cat "$H/kill.log" 2>/dev/null)"
  rm -f "$H/lsof.log" "$H/kill.log"; : > "$H/lsof.out"
  free_range 0; echo "free_range 0 (nothing listens): $?"; echo "lsof: $(cat "$H/lsof.log")"; echo "kill: $(cat "$H/kill.log" 2>/dev/null)"
  rm -f "$H/lsof.log"
  ( PATH="$win:$PATH"; free_range 1; echo "free_range 1 (netstat.exe): $?" )
  echo "tasklist: $(cat "$H/tasklist.log" 2>/dev/null | tr '\n' ';')"; echo "taskkill: $(cat "$H/taskkill.log" 2>/dev/null | tr '\n' ';')"
  echo "lsof beside netstat.exe: $(cat "$H/lsof.log" 2>/dev/null)"
}

norm() {  # norm <home>: the side's paths, ISO timestamps and epochs written out
  sed -E -e "s|$1|<H>|g" -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)/<TS>/g' \
    -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<E>\2/g' -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<E>\2/g'
}
run_side() {  # run_side <scenario> <bash|py>: the scenario's record on that side in $T/rec/<scenario>.<side>
  local sc="$1" side="$2" home="$T/$2/$1" lib
  case "$side" in bash) lib="$FIXLIB/stack.sh" ;; *) lib="$FACTORY_DIR/lib/stack.sh" ;; esac
  rm -rf "$home"; mkdir -p "$home/sh" "$home/w"
  ( export SHIPFLOOR_HOME="$home/sh" H="$home"; cd "$home/w" || exit 99
    source "$FACTORY_DIR/lib/project.sh"; source "$lib"; "scenario_$sc" ) > "$T/rec/$sc.$side.raw" 2>&1
  echo "exit $?" >> "$T/rec/$sc.$side.raw"
  norm "$home" < "$T/rec/$sc.$side.raw" > "$T/rec/$sc.$side"
}
compare() {  # compare <scenario> <label>
  run_side "$1" bash; run_side "$1" py
  if diff -q "$T/rec/$1.bash" "$T/rec/$1.py" >/dev/null; then pass "AC-1 $2: the same as the Bash version"
  else fail "AC-1 $2 differs from the Bash version (< Bash, > Python):
$(diff "$T/rec/$1.bash" "$T/rec/$1.py" | head -40)"; fi
}

compare settings "stack_settings (project and machine values, defaults, fail-open, solo, FACTORY_STACK_WAIT)"
compare state "slot_state reasons, solo_busy and the stack status TSV"
compare lease "leases: atomic mkdir, head-only zero-padded tickets, solo-blocking, gone tickets, reclaim, give-up exit 3"
compare release "stack_release_run (also through a symlink), stack_down, slot_reclaim and stacks.log"
compare env "slot_env exports and fill_ports"
compare up "stack_up exports and files, exit 3 with no slot, stack_down"
compare free "port freeing (lsof, kill -9, Docker spared; netstat.exe/tasklist.exe/taskkill.exe)"
# the records hold what each scenario is about (a scenario that silently did nothing would match too)
grep -q 'lease c (all busy): rc=3' "$T/rec/lease.py" && grep -q 'stack: no free slot after 2s' "$T/rec/lease.py" \
  && pass "AC-1 a waiter that gives up says so and exits 3" || fail "AC-1 lease record: $(cat "$T/rec/lease.py")"
grep -q 'lease e (ahead: a solo run blocked by its own project): rc=0 SLOT=1' "$T/rec/lease.py" \
  && pass "AC-1 a solo ticket blocked by its own project's slot does not hold the queue" || fail "AC-1 solo-blocking: $(grep 'lease e' "$T/rec/lease.py")"
grep -q 'reclaimed slot 1 from e hold-max' "$T/rec/lease.py" && pass "AC-1 a stuck slot is reclaimed and logged" || fail "AC-1 no reclaim in the record"
grep -qx 'kill: -9 111 555' "$T/rec/free.py" && pass "AC-1 free_range kills what listens in the range, sparing Docker" || fail "AC-1 free record: $(cat "$T/rec/free.py")"
grep -q 'stack_up u2 (no slot): rc=3' "$T/rec/up.py" && pass "AC-1 stack_up with no slot in time is exit 3" || fail "AC-1 up record: $(cat "$T/rec/up.py")"

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
