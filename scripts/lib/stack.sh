#!/usr/bin/env bash
# Stack slots: each run that needs the local stack leases a slot, which gives it a port range and
# its own compose project. The one place slot state is computed (gate.sh, dispatch.sh, aghanim and
# the dashboard all ask here). Sourced after lib/project.sh, with a resolved project.

STACK_LOCKS="$AGHANIM_HOME/locks"

stack_settings() {  # machine and project settings: STACKS BASE SPAN WAIT STALE HOLD NAME UP DOWN PORTS URL HEALTH REJECT TIMEOUT
  local m p
  mapfile -d '' -t m < <(aghanim_machine values stacks ports.base ports.span stack_wait stack_stale stack_hold_max)
  mapfile -d '' -t p < <(aghanim_cfg values project.name stack.up stack.down stack.ports stack.url stack.health stack.reject stack.timeout)
  STACKS="${m[0]:-3}" BASE="${m[1]:-20000}" SPAN="${m[2]:-20}" WAIT="${FACTORY_STACK_WAIT:-${m[3]:-1800}}" STALE="${m[4]:-90}" HOLD="${m[5]:-2700}"
  NAME="${p[0]:-project}" UP="${p[1]:-}" DOWN="${p[2]:-}" PORTS="${p[3]:-}" URL="${p[4]:-}" HEALTH="${p[5]:-}" REJECT="${p[6]:-}" TIMEOUT="${p[7]:-300}"
  [ -z "$UP" ] && STACKS=1  # a project that starts no stack of its own shares one fixed stack: one run at a time
  mkdir -p "$STACK_LOCKS/stack-queue" "$AGHANIM_HOME/logs"
}

slot_dir() { echo "$STACK_LOCKS/stack-$1.lock"; }

slot_state() {  # slot_state <k>: "free", "busy" or "stuck <reason>"
  local d owner run epoch beat now; d="$(slot_dir "$1")"; now="$(date +%s)"
  [ -d "$d" ] || { echo free; return; }
  read -r owner run epoch < "$d/info" 2>/dev/null || { echo "stuck no-info"; return; }
  beat="$(stat -c %Y "$d/beat" 2>/dev/null || echo "${epoch:-0}")"
  # a lease owned by a run lives as long as that run; the heartbeat only guards leases without one
  if [ "${run:--}" != - ] && [ ! -d "$run" ]; then echo "stuck run-ended"
  elif [ "${run:--}" = - ] && [ $(( now - beat )) -gt "$STALE" ]; then echo "stuck heartbeat"
  elif [ $(( now - ${epoch:-0} )) -gt "$HOLD" ]; then echo "stuck hold-max"
  else echo busy; fi
}

fill_ports() {  # fill_ports <k> <template>: {name} → that port of slot k
  local out="$2" name i=0
  for name in $PORTS; do out="${out//\{$name\}/$(( BASE + $1 * SPAN + i ))}"; i=$(( i + 1 )); done
  printf '%s' "$out"
}

slot_env() {  # slot_env <k>: export the slot's environment for up, down, tests and agents
  local name i=0
  export AGHANIM_SLOT="$1" AGHANIM_STACK="aghanim-$NAME-$1"
  for name in $PORTS; do export "AGHANIM_PORT_${name^^}=$(( BASE + $1 * SPAN + i ))"; i=$(( i + 1 )); done
  export AGHANIM_STACK_URL; AGHANIM_STACK_URL="$(fill_ports "$1" "$URL")"
}

free_range() {  # free_range <k>: stop what still listens on the slot's ports; Docker's own processes are left to `down`
  local lo=$(( BASE + $1 * SPAN )) hi=$(( BASE + ($1 + 1) * SPAN - 1 )) pid name
  if command -v netstat.exe >/dev/null; then
    for pid in $(netstat.exe -ano 2>/dev/null | awk -v lo="$lo" -v hi="$hi" '$1 == "TCP" && $4 == "LISTENING" { n = split($2, a, ":"); if (a[n] >= lo && a[n] <= hi) print $5 }' | sort -u); do
      name="$(tasklist.exe //FI "PID eq $pid" //FO CSV //NH 2>/dev/null | cut -d, -f1 | tr -d '"')"
      case "$name" in com.docker*|docker*|vpnkit*|wslrelay*|"") ;; *) taskkill.exe //PID "$pid" //F >/dev/null 2>&1 ;; esac
    done
  elif command -v lsof >/dev/null; then
    lsof -nP -iTCP:"$lo-$hi" -sTCP:LISTEN -Fpc 2>/dev/null |
      awk '/^p/ { p = substr($0, 2) } /^c/ && $0 !~ /^c(com\.docker|docker|vpnkit)/ { print p }' | xargs -r kill -9 2>/dev/null
  fi
  return 0
}

slot_down() {  # slot_down <k>: the slot's own stored down command (it may be another project's), then free its ports
  local d; d="$(slot_dir "$1")"
  if [ -s "$d/down" ]; then
    ( set -a; . "$d/env" 2>/dev/null; set +a; { cd "$(cat "$d/cwd" 2>/dev/null)" 2>/dev/null || cd /; }; bash -c "$(cat "$d/down")" ) >/dev/null 2>&1
  fi
  free_range "$1"
}

slot_release() {  # slot_release <k> [heartbeat]: stop its heartbeat (unless it is already dead) and drop the lock
  local d pid; d="$(slot_dir "$1")"
  [ "${2:-}" != heartbeat ] && [ -f "$d/beat.pid" ] && read -r pid < "$d/beat.pid" && kill "$pid" 2>/dev/null
  rm -rf "$d"
}

slot_reclaim() {  # slot_reclaim <k> <reason>
  local owner=?; [ -f "$(slot_dir "$1")/info" ] && read -r owner _ < "$(slot_dir "$1")/info"
  echo "$(date -Is) reclaimed slot $1 from ${owner:-?} $2" >> "$AGHANIM_HOME/logs/stacks.log"
  slot_down "$1"; slot_release "$1" "$2"
}

stack_lease() {  # stack_lease <owner>: SLOT=<k>, slots go to tickets in order, up to WAIT seconds; 3 = gave up
  local q="$STACK_LOCKS/stack-queue" t f pid run k st waited=0
  t="$q/$(date +%s%N)-$1"; echo "$$ ${AGHANIM_RUN_LOCK:--}" > "$t"
  trap 'rm -f "$t"' EXIT INT TERM
  while :; do
    for f in "$q"/*; do  # tickets of waiters or runs that are gone leave the queue
      [ -f "$f" ] || continue; read -r pid run < "$f"
      if ! kill -0 "${pid:-0}" 2>/dev/null || { [ "${run:--}" != - ] && [ ! -d "$run" ]; }; then rm -f "$f"; fi
    done
    if [ "$(ls "$q" | sort | head -1)" = "${t##*/}" ]; then
      for (( k = 0; k < STACKS; k++ )); do
        st="$(slot_state "$k")"; [ "${st%% *}" = stuck ] && slot_reclaim "$k" "${st#stuck }"
        if mkdir "$(slot_dir "$k")" 2>/dev/null; then
          echo "$1 ${AGHANIM_RUN_LOCK:--} $(date +%s)" > "$(slot_dir "$k")/info"; touch "$(slot_dir "$k")/beat"
          rm -f "$t"; trap - EXIT INT TERM; SLOT="$k"; return 0
        fi
      done
    fi
    if [ "$waited" -ge "$WAIT" ]; then rm -f "$t"; trap - EXIT INT TERM; echo "stack: no free slot after ${WAIT}s" >&2; return 3; fi
    [ $(( waited % 60 )) -eq 0 ] && echo "stack: waiting, position $(ls "$q" | sort | grep -nxF "${t##*/}" | cut -d: -f1) of $(ls "$q" | wc -l | tr -d ' ')" >&2
    sleep 1; waited=$(( waited + 1 ))
  done
}

stack_up() {  # stack_up <owner>: lease, clean the range, up, wait for health; prints the URL; 3 = infrastructure
  local d i body="" health
  stack_settings; stack_lease "$1" || return 3
  d="$(slot_dir "$SLOT")"; slot_env "$SLOT"
  env | grep -E '^AGHANIM_(SLOT|STACK|STACK_URL|PORT_[A-Z0-9]+)=' > "$d/env"; printf '%s' "$DOWN" > "$d/down"; pwd > "$d/cwd"
  ( trap '' HUP; cd /; while [ -d "$d" ]; do touch "$d/beat" 2>/dev/null; sleep 15; done ) >/dev/null 2>&1 &
  echo $! > "$d/beat.pid"
  slot_down "$SLOT"
  if [ -n "$UP" ]; then
    if ! bash -c "$UP" > "$d/up.log" 2>&1; then
      echo "stack: up failed:" >&2; tail -20 "$d/up.log" >&2; slot_down "$SLOT"; slot_release "$SLOT"; return 3
    fi
    health="$(fill_ports "$SLOT" "$HEALTH")"
    for (( i = 0; i < TIMEOUT; i++ )); do
      if [ -z "$health" ] || body="$(curl -fsS -m 5 "$health" 2>/dev/null)" && { [ -z "$REJECT" ] || ! printf '%s' "$body" | grep -Eq -- "$REJECT"; }; then
        break
      fi
      sleep 1
    done
    if [ "$i" -ge "$TIMEOUT" ]; then
      echo "stack: not healthy after ${TIMEOUT}s at $health" >&2; tail -20 "$d/up.log" >&2
      slot_down "$SLOT"; slot_release "$SLOT"; return 3
    fi
  fi
  echo "${AGHANIM_STACK_URL:-$URL}"
}

stack_down() {  # stack_down <owner>: down, free the range, release; a no-op when <owner> holds no slot
  local k owner; stack_settings
  for (( k = 0; k < STACKS; k++ )); do
    [ -f "$(slot_dir "$k")/info" ] && read -r owner _ < "$(slot_dir "$k")/info" || continue
    [ "$owner" = "$1" ] && { slot_down "$k"; slot_release "$k"; }
  done
  return 0
}

stack_release_run() {  # stack_release_run <run lock>: release every slot a finished run still holds
  local f run k
  for f in "$STACK_LOCKS"/stack-*.lock/info; do
    [ -f "$f" ] || continue; read -r _ run _ < "$f"
    [ "$run" = "$1" ] || [ "$run" -ef "$1" ] || continue
    k="${f%.lock/info}"; k="${k##*stack-}"; slot_down "$k"; slot_release "$k"
  done
}

stack_status() {  # one line per slot: k state owner held_s reason; then the queue length
  local k st owner epoch now; stack_settings; now="$(date +%s)"
  for (( k = 0; k < STACKS; k++ )); do
    st="$(slot_state "$k")"; owner=- epoch="$now"
    [ -f "$(slot_dir "$k")/info" ] && read -r owner _ epoch < "$(slot_dir "$k")/info"
    printf '%s\t%s\t%s\t%s\t%s\n' "$k" "${st%% *}" "${owner:--}" "$(( now - ${epoch:-$now} ))" "$( [ "${st%% *}" = stuck ] && echo "${st#stuck }")"
  done
  printf 'queue\t%s\n' "$(ls "$STACK_LOCKS/stack-queue" 2>/dev/null | wc -l | tr -d ' ')"
}
