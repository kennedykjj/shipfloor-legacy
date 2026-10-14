#!/usr/bin/env bash
# Stack slots: each run that needs the local stack leases a slot, which gives it a port range and its own compose
# project. The logic is shipfloor_core/stack.py; these functions are the shim gate.sh, dispatch.sh and the tests call,
# each running `sf.py stack <command>`. Sourced after lib/project.sh, with a resolved project.
#   stack_settings  sets STACKS BASE SPAN WAIT STALE HOLD NAME UP DOWN PORTS URL HEALTH REJECT TIMEOUT SOLO here;
#                   the functions after it hand those values (changed or not) to sf.py, and their $$ for the ticket
#   stack_lease/stack_up  set SLOT here (stack_up also exports the slot's SHIPFLOOR_* for the runner); they wait in
#                   the background, so INT/TERM reach this shell at once: sf.py gives its ticket or slot back, exit 3

STACK_LOCKS="$SHIPFLOOR_HOME/locks"
_STACK_SF="$SHIPFLOOR_LIB/../sf.py"
if command -v cygpath >/dev/null 2>&1; then _STACK_SF="$(cygpath -m "$_STACK_SF")"; fi  # the path Windows Python reads

_stack_prep() {  # _stack_prep [fresh]: _STACK_S = this shell's settings for sf.py ("" = read the configs)
  shipfloor_py; _STACK_S=""
  [ -z "${1:-}" ] && [ -n "${STACKS+x}" ] || return 0
  _STACK_S="$(printf '%s\037' "$STACKS" "$BASE" "$SPAN" "$WAIT" "$STALE" "$HOLD" "$NAME" "$UP" "$DOWN" "$PORTS" "$URL" \
    "$HEALTH" "$REJECT" "$TIMEOUT" "$SOLO")"
}
_stack_exec() {  # _stack_exec <command> [args]: sf.py stack with _STACK_S, in the foreground
  SHIPFLOOR_HOME="$SHIPFLOOR_HOME" SHIPFLOOR_STACK_SETTINGS="$_STACK_S" SHIPFLOOR_STACK_PID="$$" \
    "$SHIPFLOOR_PY" -I "$_STACK_SF" stack "$@"
}
_stack_sf() { _stack_prep; _stack_exec "$@"; }           # with this shell's settings (once stack_settings ran)
_stack_fresh() { _stack_prep fresh; _stack_exec "$@"; }  # with the configs' settings, read anew
_stack_bg() {  # _stack_bg <out> [fresh] <command> [args]: sf.py stack in the background, stdout to <out>; 3 on INT/TERM
  local out="$1" fresh="$2" saved rc; shift 2
  _stack_prep "$fresh"
  saved="$(trap -p INT TERM)"  # the caller's INT/TERM traps come back on every return
  trap '[ -n "${_STACK_CHILD:-}" ] && { kill -TERM "$_STACK_CHILD" 2>/dev/null; wait "$_STACK_CHILD" 2>/dev/null; }; exit 3' INT TERM
  SHIPFLOOR_HOME="$SHIPFLOOR_HOME" SHIPFLOOR_STACK_SETTINGS="$_STACK_S" SHIPFLOOR_STACK_PID="$$" \
    "$SHIPFLOOR_PY" -I "$_STACK_SF" stack "$@" > "$out" &
  _STACK_CHILD=$!
  wait "$_STACK_CHILD"; rc=$?
  _STACK_CHILD=""; trap - INT TERM; eval "$saved"
  return "$rc"
}

stack_settings() {  # machine and project settings: STACKS BASE SPAN WAIT STALE HOLD NAME UP DOWN PORTS URL HEALTH REJECT TIMEOUT SOLO
  local v
  mapfile -d '' -t v < <(_stack_fresh settings)
  STACKS="${v[0]-}" BASE="${v[1]-}" SPAN="${v[2]-}" WAIT="${v[3]-}" STALE="${v[4]-}" HOLD="${v[5]-}" NAME="${v[6]-}"
  UP="${v[7]-}" DOWN="${v[8]-}" PORTS="${v[9]-}" URL="${v[10]-}" HEALTH="${v[11]-}" REJECT="${v[12]-}" TIMEOUT="${v[13]-}" SOLO="${v[14]-}"
}

slot_dir() { echo "$STACK_LOCKS/stack-$1.lock"; }
slot_state() { _stack_sf slot-state "$1"; }        # slot_state <k>: "free", "busy" or "stuck <reason>"
fill_ports() { _stack_sf fill-ports "$1" "$2"; }   # fill_ports <k> <template>: {name} → that port of slot k
slot_env() {  # slot_env <k>: export the slot's environment for up, down, tests and agents
  local line
  while IFS= read -r line; do export "$line"; done < <(_stack_sf slot-env "$1")
}
free_range() { _stack_sf free-range "$1"; }        # free_range <k>: stop what still listens on the slot's ports
slot_down() { _stack_sf slot-down "$1"; }          # slot_down <k>: the slot's own stored down command, then free its ports
slot_release() { _stack_sf slot-release "$1" "${2:-}"; }  # slot_release <k> [heartbeat]: stop its heartbeat, drop the lock
slot_reclaim() { _stack_sf slot-reclaim "$1" "$2"; }      # slot_reclaim <k> <reason>
solo_busy() { _stack_sf solo-busy "$1"; }          # solo_busy <project>: 0 when a live slot is held by a run of it
queue_ticket() { _stack_sf queue-ticket "$1"; }    # queue_ticket <owner>: write the owner's ticket; prints its path

stack_lease() {  # stack_lease <owner>: SLOT=<k>, slots go to tickets in order, up to WAIT seconds on the clock; 3 = gave up
  local f rc; f="$(mktemp)" || return 3
  _stack_bg "$f" "" lease "$1"; rc=$?
  [ "$rc" = 0 ] && read -r SLOT < "$f"
  rm -f "$f"; [ "$rc" = 0 ] || return 3
}

stack_up() {  # stack_up <owner>: lease, clean the range, up, wait for health; prints the URL; 3 = infrastructure
  local f line rc; f="$(mktemp)" || return 3
  _stack_bg "$f.url" fresh up --export "$f" "$1"; rc=$?
  if [ "$rc" = 0 ]; then
    while IFS= read -r line; do case "$line" in SLOT=*) SLOT="${line#SLOT=}" ;; *) export "$line" ;; esac; done < "$f"
    cat "$f.url"
  fi
  rm -f "$f" "$f.url"; [ "$rc" = 0 ] || return 3
}

stack_down() { _stack_fresh down "$1"; }            # stack_down <owner>: down, free the range, release; a no-op when <owner> holds no slot
stack_release_run() { _stack_sf release-run "$1"; }  # stack_release_run <run lock>: release every slot a finished run still holds
stack_status() { _stack_fresh status; }              # one line per slot: k state owner held_s reason; then the queue length
