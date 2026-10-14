#!/usr/bin/env bash
# Where GNU stat -c is missing (macOS, BSD), a lease's age is still its true mtime: lock_live and slot_state do not
# take a live lease for a stuck one, nor a dead one for a live one. The stub below behaves like BSD stat:
# no -c, and -f %m for the mtime.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
real_stat="$(command -v stat)"; bsd="$(mktemp -d)"
cat > "$bsd/stat" <<EOS
#!/usr/bin/env bash
if [ "\${1:-}" = -f ] && [ "\${2:-}" = %m ]; then exec "$real_stat" -c %Y "\$3"; fi
echo "stat: illegal option -- \${1#-}" >&2; exit 1
EOS
chmod +x "$bsd/stat"
PATH="$bsd:$PATH" stat -c %Y / >/dev/null 2>&1 && fail "the stub still accepts stat -c" || pass "the stub rejects stat -c like BSD stat"

# ---- slot_state: a lease with no run behind it lives while its heartbeat is fresh, whatever its epoch says
slot_check() {  # slot_check <path prefix>: slot_state of a lease taken 300 s ago whose heartbeat is fresh
  (
    export SHIPFLOOR_HOME="$(mktemp -d)"; export PATH="$1$PATH"
    source "$FACTORY_DIR/lib/project.sh"; source "$FACTORY_DIR/lib/stack.sh"
    STALE=90 HOLD=2700
    mkdir -p "$(slot_dir 0)"; echo "owner - $(( $(date +%s) - 300 ))" > "$(slot_dir 0)/info"; touch "$(slot_dir 0)/beat"
    slot_state 0
  )
}
[ "$(slot_check "")" = busy ] && pass "AC-9 slot_state with GNU stat: a fresh heartbeat is busy" || fail "AC-9 slot_state with GNU stat: $(slot_check "")"
st="$(slot_check "$bsd:")"
[ "$st" = busy ] && pass "AC-9 slot_state without stat -c: the heartbeat's true mtime is read (busy)" || fail "AC-9 slot_state without stat -c says '$st', want busy (not stuck heartbeat)"
slot_stale() {  # a heartbeat that stopped 300 s ago is stuck, with or without GNU stat
  (
    export SHIPFLOOR_HOME="$(mktemp -d)"; export PATH="$1$PATH"
    source "$FACTORY_DIR/lib/project.sh"; source "$FACTORY_DIR/lib/stack.sh"
    STALE=90 HOLD=2700
    mkdir -p "$(slot_dir 0)"; echo "owner - $(date +%s)" > "$(slot_dir 0)/info"; touch -d '-300 seconds' "$(slot_dir 0)/beat"
    slot_state 0
  )
}
st="$(slot_stale "$bsd:")"
case "$st" in "stuck heartbeat") pass "AC-9 slot_state without stat -c: a stopped heartbeat is still stuck" ;; *) fail "AC-9 slot_state without stat -c says '$st' for a stopped heartbeat" ;; esac

# ---- lock_live (dispatch.sh): a lock with no epoch in its info ages by the directory's mtime
dead="$(bash -c 'echo $$')"  # a pid that has ended
cycle() {  # cycle <path prefix> <mtime args for touch>: one dispatch cycle over a develop lock with only a dead pid in info
  export SHIPFLOOR_HOME="$(mktemp -d)"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
  local t; t="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks/develop-9.lock"
  printf '#!/usr/bin/env bash\ncase "$1 ${2:-}" in "count "*) echo 0 ;; *) echo ;; esac\n' > "$t/board"; chmod +x "$t/board"
  export FACTORY_BOARD="$t/board" FACTORY_CLAUDE="$t/board"
  echo "$dead" > "$FACTORY_HOME/locks/develop-9.lock/info"
  touch -d "$2" "$FACTORY_HOME/locks/develop-9.lock"
  PATH="$1$PATH" bash "$D" >/dev/null 2>&1
}
cycle "" '5 hours ago'; [ ! -d "$FACTORY_HOME/locks/develop-9.lock" ] && pass "AC-9 lock_live with GNU stat: an old lock of a dead run is reclaimed" || fail "AC-9 lock_live with GNU stat kept an old dead lock"
cycle "$bsd:" '5 hours ago'
[ ! -d "$FACTORY_HOME/locks/develop-9.lock" ] && pass "AC-9 lock_live without stat -c: an old lock of a dead run is reclaimed (true mtime)" || fail "AC-9 lock_live without stat -c took an old dead lock for a live one"
cycle "$bsd:" '1 minute ago'
[ -d "$FACTORY_HOME/locks/develop-9.lock" ] && pass "AC-9 lock_live without stat -c: a young lock is not reclaimed" || fail "AC-9 lock_live without stat -c reclaimed a young lock"
finish
