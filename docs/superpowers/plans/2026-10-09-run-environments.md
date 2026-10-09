# Run Environments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every run that needs the local stack gets its own slot (port range + compose project) owned by the scripts, with a ticketed queue and busy/stuck states; infrastructure blocks retry once on their own; runs clean up what they created; a failed test runs once more; the dashboard shows blocks, stacks and an unblock action.

**Architecture:** A new sourced library `scripts/lib/stack.sh` holds the slot model (lease, queue, state, reclaim, up/down, health) and is the single place that computes slot state; `gate.sh` exposes it as `stack up|down|status` and wraps stack-needing test runs in it; `dispatch.sh` uses it to release a run's slot and to drive the infra retry; `board.sh` gains label reads/writes; the dashboard reads `gate.sh stack status` and the block labels.

**Tech Stack:** bash, Python 3 (config validation, dashboard), gh, docker compose (in the project's commands only).

**Spec:** `docs/superpowers/specs/2026-10-09-run-environments-design.md`

## Global Constraints

- The scripts own the stack; agents receive `AGHANIM_SLOT`, `AGHANIM_STACK`, `AGHANIM_PORT_<NAME>`, `AGHANIM_STACK_URL` and never kill processes.
- Machine config defaults: `stacks: 3`, `ports: {base: 20000, span: 20}`, `stack_wait: 1800`, `stack_stale: 90`, `stack_hold_max: 2700`.
- Slot lock: `~/.aghanim/locks/stack-<k>.lock/` with `info` = `<owner> <run lock path or -> <epoch>`, `beat` touched every 15 s; queue tickets in `~/.aghanim/locks/stack-queue/`; reclaims logged to `~/.aghanim/logs/stacks.log`.
- Slot states: free | busy | stuck (heartbeat older than `stack_stale`, owner run lock gone, or held past `stack_hold_max`).
- Gate exit 3 = infrastructure (stack not up/healthy, no slot in time). Exit 1 and 2 keep their meaning.
- Labels: `blocked` (owner) and `blocked:infra` (one automatic retry).
- Freeing a port range never kills Docker's own processes (`com.docker.*`, `docker*`, `vpnkit*`, `wslrelay*`): container ports are freed by the project's `down`.
- A project without `stack.up` keeps today's behavior: one slot (serialized), no up/down/health.
- Minimal tests (owner's rule); no dead code, narrating comments or speculative options; every `mylos` mention keeps `# legacy mylos`.

## Review Focus

Not covered by tests (Windows process and Docker behavior the suite cannot fake); reviewers check them in code:

1. `free_range` on Windows must skip Docker Desktop's processes; killing `com.docker.backend` would take every stack down.
2. The heartbeat loop must survive the `gate.sh stack up` process exiting (the UX check calls `up`, then other commands, then `down`) and must stop on `down`.
3. A reclaim of a slot held by another project must use that slot's stored `down` command and environment, not the current project's.
4. `date +%s%N` ticket names must sort correctly as strings (same digit count) so queue order holds.
5. Removing `tmp/<n>/` must remove git worktrees inside it with `git worktree remove` first, or the repo keeps dangling worktree entries.

## File Structure

- Create `scripts/lib/stack.sh` — slot model (sourced; no top-level side effects beyond function definitions).
- Modify `scripts/gate.sh` — `stack up|down|status`, stack-needing runs through `stack_around`, layer `retry`, drop `stack-lock` and `with_stack_lock`.
- Modify `scripts/aghanim_config.py` — machine keys, project `stack.*` and layer `retry` validation, describe line.
- Modify `scripts/board.sh` — `eligible` skips both block labels; `infra` lists `blocked:infra` cards; `label <n> add|remove <name>`.
- Modify `scripts/dispatch.sh` — `AGHANIM_RUN_LOCK` to runs, end-of-run cleanup (slot + `tmp/<n>/`), infra retry step.
- Modify `scripts/aghanim` — `pool` shows stacks; `clean <project>`; doctor reports stale `tmp/<n>/`.
- Modify `scripts/report.sh` — `outcome` accepts `infra`; `flaky` list.
- Modify `skills/refine|develop|validate/SKILL.md` — infra label rule, UX check via `stack up/down`, flaky lines.
- Modify `scripts/dashboard.py`, `scripts/dashboard.html` — blocked state/reason/unblock, stacks cell.
- Tests: rewrite `scripts/test/gate-stack.test.sh`, trim `scripts/test/stack-lock.test.sh`, extend `dispatch-resilience.test.sh`, `machine.test.sh`, `aghanim-cli.test.sh`, `dashboard.test.sh`, `fake-gh`.
- Pickio (manual PR): `docker-compose.yml`, `web/playwright.config.ts`, `.aghanim/factory.yml`.

---

### Task 1: Config — machine stack keys, project `stack.*`, layer `retry`

**Files:** Modify `scripts/aghanim_config.py`; Test `scripts/test/machine.test.sh`, `scripts/test/config.test.sh`

**Interfaces — Produces:** `aghanim_machine values stacks ports.base ports.span stack_wait stack_stale stack_hold_max`; `aghanim_cfg values stack.up stack.down stack.ports stack.url stack.health stack.reject stack.timeout`; layer field `retry` (int, default 0).

- [ ] **Step 1: Failing tests.** In `machine.test.sh`, before `finish`:

```bash
# stack slots and their timers have defaults and are validated like the pool
rm -f "$AGHANIM_HOME/config.yml"
assert_contains "$(m values stacks ports.base ports.span stack_wait stack_stale stack_hold_max | tr '\0' ' ')" "3 20000 20 1800 90 2700"
printf 'stacks: 0\n' > "$AGHANIM_HOME/config.yml"; assert_exit 1 m validate
printf 'ports: {base: 70000, span: 20}\n' > "$AGHANIM_HOME/config.yml"; assert_exit 1 m validate
rm -f "$AGHANIM_HOME/config.yml"
```

In `config.test.sh`, before `finish` (it already has a `validate` helper on a temp config; follow the file's pattern of writing a YAML and calling validate):

```bash
# the stack block: commands are strings, ports a list of names, timeout an integer
cfg_with() { local f; f="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$f"; printf '%s\n' "$1" >> "$f"; echo "$f"; }
assert_exit 0 env FACTORY_CONFIG="$(cfg_with 'stack: {url: "http://localhost:{web}", up: "x", down: "y", ports: [web, api], timeout: 60}')" bash "$FACTORY_DIR/aghanim-config.sh" validate
assert_exit 1 env FACTORY_CONFIG="$(cfg_with 'stack: {url: "http://localhost:3000", ports: web}')" bash "$FACTORY_DIR/aghanim-config.sh" validate
assert_exit 1 env FACTORY_CONFIG="$(cfg_with 'stack: {url: "http://localhost:{nope}", ports: [web]}')" bash "$FACTORY_DIR/aghanim-config.sh" validate
```

- [ ] **Step 2:** `bash scripts/test/run.sh machine.test.sh config.test.sh` → FAIL (unknown keys pass validation; values empty).

- [ ] **Step 3: Implement.** In `aghanim_config.py`:

```python
MACHINE_DEFAULTS = {"pool": 4, "stages": {"refine": 2, "develop": 2, "validate": 2, "deploy": 1},
                    "stacks": 3, "ports": {"base": 20000, "span": 20},
                    "stack_wait": 1800, "stack_stale": 90, "stack_hold_max": 2700}
```

In `machine_problems`, after the stages checks:

```python
    def positive(key, value):
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            errs.append(f"{key} must be an integer >= 1")
    for key in ("stacks", "stack_wait", "stack_stale", "stack_hold_max"):
        positive(key, raw.get(key, MACHINE_DEFAULTS[key]))
    ports = raw.get("ports", {})
    if not isinstance(ports, dict):
        errs.append("ports must be a mapping {base, span}")
    else:
        base = ports.get("base", MACHINE_DEFAULTS["ports"]["base"]); span = ports.get("span", MACHINE_DEFAULTS["ports"]["span"])
        positive("ports.base", base); positive("ports.span", span)
        stacks = raw.get("stacks", MACHINE_DEFAULTS["stacks"])
        if all(isinstance(v, int) for v in (base, span, stacks)) and not 1024 <= base <= base + span * stacks <= 65535:
            errs.append("ports: base .. base + span * stacks must fit 1024..65535")
```

`set` accepts `stacks`, `stack_wait`, `stack_stale`, `stack_hold_max` like `pool` (same branch, `new[args[0]] = value`); its error message lists them. `show` also prints `stacks: <n>`.

In `problems(cfg)`, extend the existing `stack` check:

```python
    st = mapping(cfg, "stack")
    for key in ("up", "down", "health", "reject"):
        if key in st and not isinstance(st[key], str):
            errs.append(f"stack.{key} must be a string")
    if "timeout" in st and (not isinstance(st["timeout"], int) or isinstance(st["timeout"], bool) or st["timeout"] < 1):
        errs.append("stack.timeout must be an integer >= 1")
    if "ports" in st and not (isinstance(st["ports"], list) and all(isinstance(p, str) and re.fullmatch(r"[a-z][a-z0-9]*", p) for p in st["ports"])):
        errs.append("stack.ports must be a list of lowercase names")
    named = set(st.get("ports") or []) if isinstance(st.get("ports"), list) else set()
    for key in ("url", "health"):
        for name in re.findall(r"\{([a-z0-9]+)\}", st.get(key) or "") if isinstance(st.get(key), str) else []:
            if name not in named:
                errs.append(f"stack.{key} uses {{{name}}}, which is not in stack.ports")
```

Add `"retry": 0` to `LAYER_DEFAULTS` and validate it in the layer loop: integer 0 or 1 (`errs.append(f"layers.{name}.retry must be 0 or 1")`). In `describe`, the layer test line appends `"  (own stack slot)"` instead of `"  (takes the stack lock)"` when `needs_stack`, and `"  retries once"` when `retry`.

- [ ] **Step 4:** `bash scripts/test/run.sh machine.test.sh config.test.sh hygiene.test.sh` → PASS.
- [ ] **Step 5:** Commit `feat(config): stack slots, project stack commands and a per-layer test retry`.

---

### Task 2: Stack slots — `scripts/lib/stack.sh` and `gate.sh stack`

**Files:** Create `scripts/lib/stack.sh`; Modify `scripts/gate.sh`; Test rewrite `scripts/test/gate-stack.test.sh`, trim `scripts/test/stack-lock.test.sh` to its acceptance-intact half.

**Interfaces — Consumes:** Task 1 keys. **Produces:** `gate.sh -C <wt> stack up <owner>` (prints the URL; exit 0, or 3 on infrastructure), `gate.sh stack down <owner>`, `gate.sh stack status` (one line per slot: `<k>\t<free|busy|stuck>\t<owner>\t<held_s>\t<reason>`, then `queue\t<n>`); in `stack.sh`: `stack_settings`, `slot_state <k>`, `stack_up <owner>`, `stack_down <owner>`, `stack_release_run <run lock>`, `stack_status`.

- [ ] **Step 1: Failing test.** Replace `scripts/test/gate-stack.test.sh` with:

```bash
#!/usr/bin/env bash
# Each run that needs the stack gets its own slot: port range, compose project, owned by the scripts.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$AGHANIM_HOME/locks"
printf 'stacks: 2\nports: {base: 21000, span: 10}\nstack_wait: 3\nstack_stale: 90\nstack_hold_max: 2700\n' > "$AGHANIM_HOME/config.yml"
cfg="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
cat >> "$cfg" <<EOF
stack:
  up: 'echo "up \$AGHANIM_SLOT \$AGHANIM_STACK \$AGHANIM_PORT_WEB \$AGHANIM_PORT_API" >> "$bin/calls"'
  down: 'echo "down \$AGHANIM_SLOT" >> "$bin/calls"'
  ports: [web, api]
  url: "http://localhost:{web}"
  health: "file://$bin/health"
  reject: "Runtime Error"
  timeout: 2
EOF
export FACTORY_CONFIG="$cfg"
echo ok > "$bin/health"
r="$(new_repo)"; cd "$r"

# two leases get different slots, ports and compose projects; up sees the slot's environment
assert_contains "$(bash "$GATE" stack up validate-1)" "http://localhost:21000"
assert_contains "$(bash "$GATE" stack up validate-2)" "http://localhost:21010"
assert_contains "$(cat "$bin/calls")" "up 0 aghanim-shop-0 21000 21001"
assert_contains "$(cat "$bin/calls")" "up 1 aghanim-shop-1 21010 21011"
assert_contains "$(bash "$GATE" stack status)" "busy	validate-1"
# a third waits, then gives up after stack_wait with exit 3
assert_exit 3 bash "$GATE" stack up validate-3
# a release lets the next one in; down ran for the released slot
assert_exit 0 bash "$GATE" stack down validate-1
assert_contains "$(cat "$bin/calls")" "down 0"
assert_contains "$(bash "$GATE" stack up validate-3)" "http://localhost:21000"
# a stale heartbeat is stuck and reclaimed by the next lease
touch -d '-5 minutes' "$L/stack-1.lock/beat"
assert_contains "$(bash "$GATE" stack status)" "stuck	validate-2"
bash "$GATE" stack down validate-3 >/dev/null
assert_contains "$(bash "$GATE" stack up validate-4)" "http://localhost:21000"
assert_contains "$(bash "$GATE" stack up validate-5)" "http://localhost:21010"
assert_contains "$(cat "$AGHANIM_HOME/logs/stacks.log")" "validate-2 heartbeat"
bash "$GATE" stack down validate-4 >/dev/null; bash "$GATE" stack down validate-5 >/dev/null
# a body matching stack.reject is unhealthy: exit 3, down ran, slot released
echo "Unhandled Runtime Error" > "$bin/health"; : > "$bin/calls"
assert_exit 3 bash "$GATE" stack up validate-6
assert_contains "$(cat "$bin/calls")" "down 0"
[ ! -d "$L/stack-0.lock" ] && pass "unhealthy stack released its slot" || fail "slot kept after a failed up"
# waiters take slots in ticket order
echo ok > "$bin/health"
bash "$GATE" stack up a >/dev/null; bash "$GATE" stack up b >/dev/null
( printf '%s\n' "$(bash "$GATE" stack up first)" > "$bin/first" ) & sleep 1
( printf '%s\n' "$(bash "$GATE" stack up second)" > "$bin/second" ) & sleep 1
bash "$GATE" stack down a >/dev/null; sleep 2
assert_contains "$(cat "$bin/first")" "http://localhost:21000"
wait
finish
```

Trim `stack-lock.test.sh` to its last block (acceptance-intact ignores files the QA commit deleted), with the header comment `# acceptance-intact ignores files the QA commit deleted.`

- [ ] **Step 2:** `bash scripts/test/run.sh gate-stack.test.sh` → FAIL (`gate.sh: usage` for `stack`).

- [ ] **Step 3: Implement `scripts/lib/stack.sh`.**

```bash
#!/usr/bin/env bash
# Stack slots: each run that needs the local stack leases a slot, which gives it a port range and
# its own compose project. Sourced by gate.sh and dispatch.sh; the one place slot state is computed.
# Needs lib/project.sh (aghanim_machine, aghanim_cfg) and a resolved project.

STACK_LOCKS="$AGHANIM_HOME/locks"

stack_settings() {  # machine and project settings into STACKS BASE SPAN WAIT STALE HOLD UP DOWN PORTS URL HEALTH REJECT TIMEOUT
  local m p
  mapfile -d '' -t m < <(aghanim_machine values stacks ports.base ports.span stack_wait stack_stale stack_hold_max)
  mapfile -d '' -t p < <(aghanim_cfg values stack.up stack.down stack.ports stack.url stack.health stack.reject stack.timeout)
  STACKS="${m[0]:-3}" BASE="${m[1]:-20000}" SPAN="${m[2]:-20}" WAIT="${FACTORY_STACK_WAIT:-${m[3]:-1800}}" STALE="${m[4]:-90}" HOLD="${m[5]:-2700}"
  UP="${p[0]:-}" DOWN="${p[1]:-}" PORTS="${p[2]:-}" URL="${p[3]:-}" HEALTH="${p[4]:-}" REJECT="${p[5]:-}" TIMEOUT="${p[6]:-300}"
  [ -z "$UP" ] && STACKS=1  # a project that starts no stack of its own shares the one fixed stack: one run at a time
  mkdir -p "$STACK_LOCKS/stack-queue" "$AGHANIM_HOME/logs"
}

slot_dir() { echo "$STACK_LOCKS/stack-$1.lock"; }

slot_state() {  # slot_state <k>: "free", "busy" or "stuck <reason>"
  local d owner run epoch beat now; d="$(slot_dir "$1")"; now="$(date +%s)"
  [ -d "$d" ] || { echo free; return; }
  read -r owner run epoch < "$d/info" 2>/dev/null || { echo "stuck no-info"; return; }
  beat="$(stat -c %Y "$d/beat" 2>/dev/null || echo "${epoch:-0}")"
  if [ $(( now - beat )) -gt "$STALE" ]; then echo "stuck heartbeat"
  elif [ "$run" != - ] && [ ! -d "$run" ]; then echo "stuck run-ended"
  elif [ $(( now - epoch )) -gt "$HOLD" ]; then echo "stuck hold-max"
  else echo busy; fi
}

slot_env() {  # slot_env <k>: export the slot's environment for up, down, tests and agents
  local k="$1" i=0 name url
  export AGHANIM_SLOT="$k" AGHANIM_STACK="aghanim-${FACTORY_PROJECT:-project}-$k"
  url="$URL"
  for name in $PORTS; do
    export "AGHANIM_PORT_${name^^}=$(( BASE + k * SPAN + i ))"
    url="${url//\{$name\}/$(( BASE + k * SPAN + i ))}"; i=$(( i + 1 ))
  done
  export AGHANIM_STACK_URL="$url"
}

free_range() {  # free_range <k>: stop what still listens in the slot's ports; Docker's own processes are left to `down`
  local lo=$(( BASE + $1 * SPAN )) hi=$(( BASE + ($1 + 1) * SPAN - 1 ))
  if command -v powershell.exe >/dev/null; then
    powershell.exe -NoProfile -NonInteractive -Command "Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Where-Object { \$_.LocalPort -ge $lo -and \$_.LocalPort -le $hi } | ForEach-Object { Get-Process -Id \$_.OwningProcess -ErrorAction SilentlyContinue } |
      Where-Object { \$_.Name -notmatch '^(com\.docker|docker|vpnkit|wslrelay)' } | Stop-Process -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
  elif command -v lsof >/dev/null; then
    lsof -nP -iTCP:"$lo-$hi" -sTCP:LISTEN -Fpc 2>/dev/null | awk '/^p/{p=substr($0,2)} /^c/{if ($0 !~ /^c(com\.docker|docker|vpnkit)/) print p}' | xargs -r kill -9 2>/dev/null
  fi
  return 0
}

slot_down() {  # slot_down <k>: the slot's own stored down command, then free its ports
  local d; d="$(slot_dir "$1")"
  if [ -s "$d/down" ]; then
    ( set -a; . "$d/env" 2>/dev/null; set +a; cd "$(cat "$d/cwd" 2>/dev/null || echo .)" && bash -c "$(cat "$d/down")" ) >/dev/null 2>&1
  fi
  free_range "$1"
}

slot_release() {  # slot_release <k>
  local d pid; d="$(slot_dir "$1")"
  read -r pid < "$d/beat.pid" 2>/dev/null && kill "$pid" 2>/dev/null
  rm -rf "$d"
}

slot_reclaim() {  # slot_reclaim <k> <reason>
  local owner; read -r owner _ < "$(slot_dir "$1")/info" 2>/dev/null
  echo "$(date -Is) reclaimed slot $1 from ${owner:-?} $2" >> "$AGHANIM_HOME/logs/stacks.log"
  slot_down "$1"; slot_release "$1"
}

stack_lease() {  # stack_lease <owner>: SLOT=<k>, in ticket order, up to WAIT seconds; 3 = gave up
  local q="$STACK_LOCKS/stack-queue" t f run k st waited=0
  t="$q/$(date +%s%N)-$1"; echo "${AGHANIM_RUN_LOCK:--}" > "$t"
  while :; do
    for f in "$q"/*; do  # tickets of runs that ended leave the queue
      [ -f "$f" ] || continue; read -r run < "$f"; [ "$run" != - ] && [ ! -d "$run" ] && rm -f "$f"
    done
    if [ "$(ls "$q" | sort | head -1)" = "${t##*/}" ]; then
      for (( k = 0; k < STACKS; k++ )); do
        st="$(slot_state "$k")"; [ "${st%% *}" = stuck ] && slot_reclaim "$k" "${st#stuck }"
        if mkdir "$(slot_dir "$k")" 2>/dev/null; then
          echo "$1 ${AGHANIM_RUN_LOCK:--} $(date +%s)" > "$(slot_dir "$k")/info"; touch "$(slot_dir "$k")/beat"
          rm -f "$t"; SLOT="$k"; return 0
        fi
      done
    fi
    if [ "$waited" -ge "$WAIT" ]; then rm -f "$t"; echo "stack: no free slot after ${WAIT}s" >&2; return 3; fi
    [ $(( waited % 60 )) -eq 0 ] && echo "stack: waiting, position $(ls "$q" | sort | grep -nx "${t##*/}" | cut -d: -f1) of $(ls "$q" | wc -l | tr -d ' ')" >&2
    sleep 1; waited=$(( waited + 1 ))
  done
}

stack_up() {  # stack_up <owner>: lease, clean the range, up, wait for health; prints the URL; 3 = infrastructure
  local d i code body
  stack_settings; stack_lease "$1" || return 3
  d="$(slot_dir "$SLOT")"; slot_env "$SLOT"
  env | grep '^AGHANIM_\(SLOT\|STACK\|PORT_\|STACK_URL\)' > "$d/env"; printf '%s' "$DOWN" > "$d/down"; pwd > "$d/cwd"
  ( trap '' HUP; while [ -d "$d" ]; do touch "$d/beat" 2>/dev/null; sleep 15; done ) >/dev/null 2>&1 &
  echo $! > "$d/beat.pid"
  slot_down "$SLOT"
  if [ -n "$UP" ]; then
    if ! bash -c "$UP" > "$d/up.log" 2>&1; then
      echo "stack: up failed:" >&2; tail -20 "$d/up.log" >&2; slot_down "$SLOT"; slot_release "$SLOT"; return 3
    fi
    for (( i = 0; i < TIMEOUT; i++ )); do
      body="$(curl -fsS -m 5 "${HEALTH//\{web\}/${AGHANIM_PORT_WEB:-}}" 2>/dev/null)"; code=$?
      [ "$code" -eq 0 ] && { [ -z "$REJECT" ] || ! printf '%s' "$body" | grep -Eq -- "$REJECT"; } && break
      sleep 1
    done
    if [ "$i" -ge "$TIMEOUT" ]; then
      echo "stack: not healthy after ${TIMEOUT}s at $HEALTH" >&2; tail -20 "$d/up.log" >&2
      slot_down "$SLOT"; slot_release "$SLOT"; return 3
    fi
  fi
  echo "${AGHANIM_STACK_URL:-$URL}"
}

stack_down() {  # stack_down <owner>: down, free the range, release; a no-op when <owner> holds no slot
  local k owner; stack_settings
  for (( k = 0; k < STACKS; k++ )); do
    read -r owner _ < "$(slot_dir "$k")/info" 2>/dev/null || continue
    [ "$owner" = "$1" ] && { slot_down "$k"; slot_release "$k"; }
  done
  return 0
}

stack_release_run() {  # stack_release_run <run lock>: release every slot a finished run still holds
  local f run k
  for f in "$STACK_LOCKS"/stack-*.lock/info; do
    [ -f "$f" ] || continue; read -r _ run _ < "$f"
    [ "$run" = "$1" ] || continue
    k="${f%.lock/info}"; k="${k##*stack-}"; slot_down "$k"; slot_release "$k"
  done
}

stack_status() {  # one line per slot: k state owner held_s reason; then the queue length
  local k st owner epoch; stack_settings
  for (( k = 0; k < STACKS; k++ )); do
    st="$(slot_state "$k")"; owner=- epoch="$(date +%s)"
    read -r owner _ epoch < "$(slot_dir "$k")/info" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\n' "$k" "${st%% *}" "$owner" "$(( $(date +%s) - epoch ))" "$( [ "${st%% *}" = stuck ] && echo "${st#stuck }")"
  done
  printf 'queue\t%s\n' "$(ls "$STACK_LOCKS/stack-queue" 2>/dev/null | wc -l | tr -d ' ')"
}
```

Note for the implementer: the health check accepts any URL curl can read; the test uses `file://`. Placeholders in `health` other than `{web}` are filled like `url` by reusing `slot_env`'s substitution: compute the health URL with the same loop (extract a helper `fill_ports <template>` used for both `url` and `health` instead of the `{web}`-only replace above).

**`gate.sh`:**

- `source "$HERE/lib/stack.sh"` after `lib/project.sh`.
- Delete `STACK_LOCK`, `STACK_TTL`, `stack_acquire`, `stack_release`, `with_stack_lock`, `gate_stack_lock` and the `stack-lock)` case; add:

```bash
gate_stack() {  # gate.sh stack up <owner> | down <owner> | status
  case "${1:-}" in
    up)     [ -n "${2:-}" ] || return 2; stack_up "$2" ;;
    down)   [ -n "${2:-}" ] || return 2; stack_down "$2" ;;
    status) stack_status ;;
    *) echo "stack: up <owner> | down <owner> | status" >&2; return 2 ;;
  esac
}

stack_around() {  # stack_around <command...>: run it with its own stack when the layer needs one; 3 = infrastructure
  [ "$L_STACK" = true ] || { "$@"; return; }
  local owner="gate-$$"
  stack_up "$owner" >/dev/null || return 3
  "$@"; local code=$?
  stack_down "$owner"; return $code
}
```

  and `stack)            gate_stack "$@" ;;` in the command `case`.
- `run_selector` loses its stack-lock line.
- `load_layer` also reads `retry` into `L_RETRY` (`layer_fields "$1" path test ran assertions setup_errors needs_stack retry`).
- `gate_red` and `gate_green` move their bodies into `red_run` / `green_run` and call `stack_around red_run "$@"` / `stack_around green_run "$@"`. The header line becomes `# Exit 0 = pass, 1 = blocked (details on stderr), 2 = bad usage or bad revision (never a pass), 3 = infrastructure.`
- Usage line lists `stack`.

- [ ] **Step 4:** `bash scripts/test/run.sh gate-stack.test.sh stack-lock.test.sh gate-layers.test.sh gate-review.test.sh hygiene.test.sh` → PASS.
- [ ] **Step 5:** Commit `feat(gate): one stack slot per run, with a ticketed queue and busy/stuck states`.

---

### Task 3: Retry a failed test once

**Files:** Modify `scripts/gate.sh`; Test `scripts/test/gate-build.test.sh` (or the file that tests `green`; append there).

- [ ] **Step 1: Failing test** (append before `finish` in the file that already builds a `green` fixture; adapt names to that file's helpers):

```bash
# retry: 1 — a selector that fails, then passes, passes the gate and is reported flaky; red never retries
cfg="$(mktemp)"; sed 's/^\(    test: .*vitest.*\)$/\1\n    retry: 1/' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
bin="$(mktemp -d)"; printf '#!/usr/bin/env bash\nif [ -e "%s/once" ]; then echo " Test Files  1 passed (1)"; exit 0; fi\ntouch "%s/once"; echo " Test Files  1 failed (1)"; exit 1\n' "$bin" "$bin" > "$bin/pnpm"; chmod +x "$bin/pnpm"
out="$(env FACTORY_CONFIG="$cfg" FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web web/a.test.ts 2>&1)"; code=$?
[ "$code" = 0 ] && pass "flaky test passes on retry" || fail "retry did not pass: $out"
assert_contains "$out" "flaky: web web/a.test.ts"
rm -f "$bin/once"; assert_exit 0 env FACTORY_CONFIG="$cfg" FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web web/a.test.ts
```

(The fixture's `web` layer test command and `ran`/`assertions` patterns decide the exact runner output; copy them from the fixture when writing the fake runner. `red` passing here proves it did not retry: the first run fails by assertion, which is what `red` wants.)

- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** In `green_run`, after `out="$(run_selector "$layer" "$sel")"; code=$?`:

```bash
  if [ "$code" -ne 0 ] && [ "${L_RETRY:-0}" -ge 1 ]; then
    out="$(run_selector "$layer" "$sel")"; code=$?
    [ "$code" -eq 0 ] && echo "flaky: $layer $sel"
  fi
```

- [ ] **Step 4:** run → PASS. **Step 5:** Commit `feat(gate): a layer may retry a failed test once; the pass is reported flaky`.

---

### Task 4: Dispatcher — run lock to runs, cleanup by ownership, infra retry; board labels

**Files:** Modify `scripts/dispatch.sh`, `scripts/board.sh`; Test `scripts/test/dispatch-resilience.test.sh`, `scripts/test/board.test.sh` (one case), `scripts/test/fake-gh`.

**Interfaces — Consumes:** `stack_release_run` (Task 2). **Produces:** `board.sh infra` (numbers of open issues labeled `blocked:infra`), `board.sh label <n> add|remove <label>`; `eligible` skips `blocked` and `blocked:infra`; runs get `AGHANIM_RUN_LOCK=<lock dir>` and, on the retry, `AGHANIM_INFRA_RETRY=1`; marker `$FACTORY_HOME/infra/<n>`.

- [ ] **Step 1: Failing tests.** In `dispatch-resilience.test.sh`, extend the fake board's `case` with:

```bash
  "infra "*) for n in ${INFRA:-}; do echo "$n"; done ;;
  "label "*) echo "$*" >> "$FACTORY_HOME/labels" ;;
```

and the fake claude records the retry flag: `printf '#!/usr/bin/env bash\necho "$(cat) $* retry=${AGHANIM_INFRA_RETRY:-0}" >> "%s/launched"\n'`. Add before `finish`:

```bash
# blocked:infra: cleaned (tmp/<n>/ goes), label removed and relaunched once with AGHANIM_INFRA_RETRY=1
setup; INFRA="70" O_VAL="70"; mkdir -p "$FACTORY_HOME/tmp/70/junk"; run_dispatch
assert_contains "$(cat "$FACTORY_HOME/labels")" "label 70 remove blocked:infra"
assert_contains "$(cat "$tmp/launched")" "/aghanim:validate 70 retry=1"
[ ! -e "$FACTORY_HOME/tmp/70" ] && pass "infra leftovers cleaned" || fail "tmp/70 kept"
[ ! -e "$FACTORY_HOME/infra/70" ] && pass "retry marker cleared when the run ended" || fail "marker kept"
# a card already retried and labeled blocked:infra again goes to the owner, not relaunched
setup; INFRA="71"; mkdir -p "$FACTORY_HOME/infra"; date +%s > "$FACTORY_HOME/infra/71"; run_dispatch
assert_contains "$(cat "$FACTORY_HOME/labels")" "label 71 add blocked"
case "$(cat "$tmp/launched")" in *71*) fail "relaunched a card whose retry failed" ;; *) pass "second infra block goes to the owner" ;; esac
```

In `fake-gh`, add before the `*)` line:

```bash
  "api repos/acme/shop/issues?labels=blocked:infra"*) cat "$d/infra" 2>/dev/null ;;
  "api -X POST repos/acme/shop/issues/"*"/labels"*|"api -X DELETE repos/acme/shop/issues/"*"/labels/"*) ;;
```

and in `board.test.sh` one case: `printf '7\n' > "$FAKE_GH_DIR/infra"; assert_contains "$(bash "$B" infra)" "7"` plus `eligible` skipping a card whose labels file holds `blocked:infra` (follow the file's existing `labels-<n>` pattern).

- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: `board.sh`:**

```bash
infra() { "$GH" api "repos/$REPO/issues?labels=blocked:infra&state=open&per_page=100" --jq '.[].number'; }
label() {  # label <n> add|remove <name>
  case "$2" in
    add) "$GH" api -X POST "repos/$REPO/issues/$1/labels" -f "labels[]=$3" >/dev/null ;;
    remove) "$GH" api -X DELETE "repos/$REPO/issues/$1/labels/$3" >/dev/null 2>&1 || true ;;
    *) return 2 ;;
  esac
}
```

`eligible`'s check becomes `printf '%s\n' "$labels" | tr -d '\r' | grep -qxE 'blocked|blocked:infra' || out="$out$n"$'\n'`; the command `case` and usage line add `infra|label`.

**`dispatch.sh`:**

- `source "$HERE/lib/stack.sh"` after `lib/project.sh`.
- In `launch`, the agent env gets `AGHANIM_RUN_LOCK="$dir"` and, when `[ -e "$HOME_DIR/infra/$n" ]`, `AGHANIM_INFRA_RETRY=1` (build an `envs` array before `agent()` and use it in the `env` call; the deploy branch gets the same array).
- After the run ends (both branches, before `cleanup_processes`):

```bash
    stack_settings 2>/dev/null; stack_release_run "$dir"
    clean_tmp "$n"; rm -f "$HOME_DIR/infra/$n"
```

- New helper next to `cleanup_processes`:

```bash
clean_tmp() {  # clean_tmp <n>: worktrees a run left under tmp/<n>/, then the directory
  local t="$HOME_DIR/tmp/$1" w
  [ -d "$t" ] || return 0
  for w in $(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n "s#^worktree ##p" | grep -F "$(aghanim_native "$t")/"); do
    git -C "$REPO" worktree remove --force "$w" 2>/dev/null
  done
  git -C "$REPO" worktree prune 2>/dev/null; rm -rf "$t"
}
```

- Before the `run_pipeline` calls:

```bash
retry_infra() {  # cards blocked by infrastructure: clean up and retry once; a second block goes to the owner
  local n cards; cards="$("$BOARD" infra)" || return 1
  mkdir -p "$HOME_DIR/infra"
  for n in $cards; do
    card_busy "$n" && continue
    if [ -e "$HOME_DIR/infra/$n" ]; then "$BOARD" label "$n" add blocked; "$BOARD" label "$n" remove blocked:infra; continue; fi
    clean_tmp "$n"; date +%s > "$HOME_DIR/infra/$n"; "$BOARD" label "$n" remove blocked:infra
  done
}
retry_infra || status=1
```

(Move `status=0` above it.) The relaunch itself comes from the existing loops: the card is eligible again in its column.

- [ ] **Step 4:** `bash scripts/test/run.sh dispatch-resilience.test.sh board.test.sh dispatch.test.sh dispatch-stack.test.sh` → PASS (update `dispatch-stack.test.sh` if it asserts the old `stack.lock` cleanup: the run's slot release replaces it).
- [ ] **Step 5:** Commit `feat(dispatch): runs release their stack slot and tmp/<n>; infrastructure blocks retry once`.

---

### Task 5: Skills, report, CLI

**Files:** Modify `skills/refine/SKILL.md`, `skills/develop/SKILL.md`, `skills/validate/SKILL.md`, `scripts/report.sh`, `scripts/aghanim`, `README.md`; Test `scripts/test/aghanim-cli.test.sh`, `scripts/test/report.test.sh` (one case).

- [ ] **Step 1: Failing tests.** `report.test.sh`: a report with `"outcome": "infra"` and `"flaky": ["web web/a.test.ts"]` is accepted (follow the file's pattern). `aghanim-cli.test.sh`:

```bash
# clean removes tmp/<n>/ of cards that are Done or off the board, keeps the active ones
H2="$AGHANIM_HOME/projects/shop"; mkdir -p "$H2/tmp/5" "$H2/tmp/6"; printf '5\tDone\tI5\n6\tCoding\tI6\n' > "$H2/board.tsv"
assert_exit 0 bash "$M" clean shop
[ ! -e "$H2/tmp/5" ] && [ -d "$H2/tmp/6" ] && pass "clean keeps active cards" || fail "clean removed the wrong tmp dirs"
```

- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:**
  - `report.sh`: `outcome` in `ok|blocked|infra`; optional `flaky` array of strings; schema comment updated.
  - Skills, replacing the infrastructure sentence in each of refine/develop/validate: "Infrastructure errors (a gate exit 3, Docker, network, a runner crash outside the code) are not rounds: when `AGHANIM_INFRA_RETRY` is `1`, label `blocked` and say the automatic retry failed; otherwise label `blocked:infra` (the dispatcher cleans up and retries once). Comment the step, the output and what was tried; report `outcome: infra`." Every gate result line that prints `flaky: …` is copied into the report's `flaky` list.
  - `validate/SKILL.md` UX step: "take a stack with `url=$(gate.sh -C <worktree> stack up validate-<n>)` (it waits in the queue; exit 3 is infrastructure), call `ux-designer` mode `validate` with `url=<url>`, then `gate.sh stack down validate-<n>` right away; never hold a stack while waiting for CI or running gates (gates of stack layers take their own)."
  - `agents/ux-designer.md`: "open the stack at the `url=` it was given (else the describe URL)".
  - `scripts/aghanim`: `pool` appends `stacks:` and one line per slot from `bash "$HERE/gate.sh" stack status` (run with the first registered project's config); new `clean <project>` removing `tmp/<n>/` whose card is `Done` or absent in `board.tsv` (worktrees first, as `clean_tmp`); `doctor` warns `tmp: <n> dir(s) of finished cards; run: aghanim clean <project>`; header usage line for `clean`.
  - README Operation line adds `aghanim clean <project>`.
- [ ] **Step 4:** `bash scripts/test/run.sh aghanim-cli.test.sh report.test.sh hygiene.test.sh` → PASS.
- [ ] **Step 5:** Commit `feat: infra blocks in the skills, flaky tests in reports, aghanim clean and stacks in pool`.

---

### Task 6: Dashboard — blocks, unblock, stacks

**Files:** Modify `scripts/dashboard.py`, `scripts/dashboard.html`; Test `scripts/test/dashboard.test.sh`, `scripts/test/fake-gh`.

**Interfaces — Produces:** overview `stacks: [{"slot","state","owner","held_s","reason"}]`, `queue: <n>`, cards gain `blocked: null|"infra"|"owner"`; card gains `block_reason`; `POST /api/card/<p>/<n>/unblock`.

- [ ] **Step 1: Failing test** (append to `dashboard.test.sh` before `finish`):

```bash
# unblock: owner action, header token only, removes both block labels
[ "$(post -d '{}' "$base/api/card/shop/7/unblock")" = 403 ] && pass "no token, no unblock" || fail "unblocked without the token"
[ "$(post -d '{}' "$base/api/card/shop/7/unblock" -H "$H_TOK")" = 200 ] && pass "unblocked" || fail "unblock failed"
assert_contains "$(cat "$FAKE_GH_DIR/calls")" "api -X DELETE repos/acme/shop/issues/7/labels/blocked:infra"
```

- [ ] **Step 2:** run → FAIL (404).
- [ ] **Step 3:**
  - `Factory.blocked(p)`: cached 60 s like `titles`; two `gh api "repos/<repo>/issues?labels=<label>&state=open&per_page=100" --jq '.[].number'` calls → `{n: "infra"|"owner"}` (owner wins when both).
  - `Factory.stacks()`: run `bash gate.sh stack status` with the first project's `FACTORY_CONFIG`/`FACTORY_HOME` env (same env as `act`), parse lines.
  - overview adds `stacks`, `queue`, and each card's `blocked`; `card()` adds `block_reason` = notes of the last report whose outcome is `blocked` or `infra`.
  - `act()` accepts `unblock` in any column: two `gh api -X DELETE …/labels/blocked` and `…/labels/blocked:infra` (failures for a missing label ignored); returns `{"unblocked": true}`. `do_POST` allows `unblock`.
  - Page: a card with `blocked` shows a marker line (`blocked`, or `infra · retrying`) in `--bad`/`--warn`; the drawer shows `block_reason` above the tabs with an "Unblock & retry" button (secondary style; Approve stays the only filled action); the top strip gets a `stacks` stat `busy/total` with a meter and a title listing each slot (`0 busy #86 validate 04:12`, `1 stuck … heartbeat`), the stat turns `--warn` when any slot is stuck; queue length shown as `+N waiting`.
- [ ] **Step 4:** `bash scripts/test/run.sh dashboard.test.sh hygiene.test.sh` → PASS; capture with `playwright-cli -s=dash` (never the default session) desktop dark/light; one design pass with `/impeccable` on the changed parts.
- [ ] **Step 5:** Commit `feat(dashboard): blocked cards, unblock and retry, stack slots`.

---

### Task 7: Pickio — stack per slot (manual PR, owner approves the merge)

**Files (Pickio repo, branch off `main`):** `docker-compose.yml`, `web/playwright.config.ts`, `.aghanim/factory.yml`.

- [ ] **Step 1:** In `docker-compose.yml`, every published port takes its variable with today's port as default: `"${AGHANIM_PORT_API:-8080}:8080"`, `"${AGHANIM_PORT_WEB:-3000}:3000"`, `"${AGHANIM_PORT_DB:-5432}:5432"`, `"${AGHANIM_PORT_S3:-9000}:9000"`, `"${AGHANIM_PORT_S3CONSOLE:-9001}:9001"`, `"${AGHANIM_PORT_SMTP:-1025}:1025"`, `"${AGHANIM_PORT_MAIL:-8025}:8025"` (match the file's actual services and ports). Browser-facing values (web's API base URL, API CORS origin, MinIO public endpoint) take the same variables with today's values as defaults; service-to-service URLs keep compose names. Read the file first and keep every other line as is.
- [ ] **Step 2:** `web/playwright.config.ts`: `baseURL: process.env.AGHANIM_STACK_URL ?? 'http://localhost:3000'`; `webServer: process.env.AGHANIM_STACK_URL ? undefined : { command: 'pnpm dev', port: 3000, reuseExistingServer: !process.env.CI }`.
- [ ] **Step 3:** `.aghanim/factory.yml`: the `stack:` block from the spec, with `ports` in the order of Step 1.
- [ ] **Step 4:** Check by hand: `AGHANIM_PORT_WEB=21000 … docker compose -p aghanim-pickio-0 up -d --build --wait`, open `http://localhost:21000`, `down -v`; plain `docker compose up` still serves on 3000.
- [ ] **Step 5:** PR in Portuguese per Pickio conventions; owner merges; then `aghanim add ~/git/pickio` (refresh), `gh issue edit 86 --remove-label blocked`.

---

## Self-review notes

- Spec coverage: slots/queue/states (T2), machine/project config (T1), exit 3 (T2), infra labels and retry (T4, T5), cleanup by ownership and `aghanim clean`/doctor (T4, T5), flaky retry (T3, T5), dashboard (T6), Pickio (T7).
- Deviations, to be ledgered as rulings at execution: the retry marker is a file `$FACTORY_HOME/infra/<n>` instead of the spec's report field `infra_retry` (simpler, cleared when the retried run ends); the retry applies to `green` only (`acceptance-intact` checks file integrity and runs no tests); a project without `stack.up` gets one slot.
