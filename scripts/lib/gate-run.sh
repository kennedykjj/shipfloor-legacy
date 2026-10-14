#!/usr/bin/env bash
# The gates that run a layer's commands: build, red, green and stack (the Bash code of gate.sh, moved here unchanged
# until they are ported). scripts/gate.sh hands them its arguments as they came, -C included; the static gates are Python
# (shipfloor_core.gate). Exit 0 = pass, 1 = blocked (details on stderr), 2 = bad usage or bad revision (never a pass),
# 3 = infrastructure (the run's stack did not come up, or no stack slot in time).
set -uo pipefail

LIB="${0%[/\\]*}"; [ "$LIB" != "$0" ] || LIB=.; HERE="$(cd "$LIB/.." && pwd)"  # HERE = scripts/, as in gate.sh; no dirname: one process less
source "$HERE/lib/project.sh"
source "$HERE/lib/stack.sh"

# gate.sh -C <worktree> ...: run against that worktree (pipelines never `cd`).
if [ "${1:-}" = "-C" ]; then
  cd "${2:-}" 2>/dev/null || { echo "gate: cannot enter '${2:-}'" >&2; exit 2; }
  shift 2
fi

# Paths, layers and commands come from the project's config (its control checkout), never from
# the worktree under test. No project or a broken config is exit 2, never a pass.
shipfloor_resolve . || exit 2
root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }  # asked only by the gates that run a layer's command
g() { git -c core.quotePath=false "$@"; }
q() {  # q <query...>: one config answer; a failing query stops the gate with exit 2
  local out; out="$(shipfloor_cfg "$@")" || { echo "gate: config query failed: $*" >&2; exit 2; }
  printf '%s' "$out"
}
layer_fields() {  # layer_fields <layer> <field>...: values into the array LF; 2 = unknown layer
  LF=()
  mapfile -d '' -t LF < <(shipfloor_cfg fields "$@" 2>/dev/null)
  [ "${#LF[@]}" -eq $(( $# - 1 )) ] || { echo "gate: unknown layer '$1'" >&2; return 2; }
}
load_layers() {  # only the gates that iterate layers pay for reading them
  [ -n "${ALL_LAYERS+set}" ] && return 0
  ALL_LAYERS="$(q layers)" || exit 2
  IMPLEMENTERS="$(q layers --implementers)" || exit 2
}

require_rev() {  # exits 2 unless $1 names a commit
  if [ -z "${1:-}" ] || ! git rev-parse --verify -q "$1^{commit}" >/dev/null; then
    echo "gate: bad revision '${1:-}'" >&2; exit 2
  fi
}

raw_changes() {  # NUL-separated names: committed since base, uncommitted, and untracked (never C-quoted)
  g diff -z --name-only --no-renames "$1" HEAD; g diff -z --name-only --no-renames HEAD; g ls-files -z --others --exclude-standard
}

changed_files() {  # one name per line
  raw_changes "$1" | tr '\0' '\n' | sed '/^$/d' | sort -u
}

ensure_deps() {  # ensure_deps <layer dir> <install command>: the layer's dependencies, installed by the gate, not by an agent
  # Once per content of the layer's directory (its tree at HEAD), remembered inside the git dir so the
  # worktree stays clean. A failing install is infrastructure: exit 3, never a red or green verdict.
  [ -n "$2" ] || return 0
  local mark key
  mark="$(git rev-parse --absolute-git-dir)/shipfloor-install-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"
  key="$(git rev-parse -q --verify "HEAD:${1%/}" 2>/dev/null) $2"
  [ "$(cat "$mark" 2>/dev/null)" = "$key" ] && return 0
  (cd "$(root)/$1" && bash -c "$2") >&2 || { echo "gate: install failed in $1: $2" >&2; return 3; }
  printf '%s' "$key" > "$mark"
}

# The pass record's key hashes scripts/gate.sh, the file callers run (its content, not its path): a gate that changes
# invalidates the passes recorded before it.
pass_key() {  # pass_key <gate> <arguments> <key line>...: PASS_FILE = where this call's pass is recorded; empty = run, record nothing
  # Only a clean worktree, a store outside it and no SHIPFLOOR_GATE_FRESH=1 count. The key is read before the command runs.
  PASS_FILE="" PASS_GATE="$1" PASS_ARGS="$2"; shift 2
  [ "${SHIPFLOOR_GATE_FRESH:-}" != 1 ] && [ -n "${FACTORY_HOME:-}" ] && [ -z "$(git status --porcelain 2>/dev/null)" ] || return 0
  local top home store cfg me
  top="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" && home="$(cd "$FACTORY_HOME" 2>/dev/null && pwd -P)" || return 0
  case "$home/" in "$top"/*) return 0 ;; esac
  mkdir -p "$home/gate-passes" && store="$(cd "$home/gate-passes" && pwd -P)" || return 0
  case "$store/" in "$top"/*) return 0 ;; esac
  cfg="$(git hash-object --no-filters -- "${FACTORY_CONFIG:-}" 2>/dev/null)" && me="$(git hash-object --no-filters -- "$HERE/gate.sh" 2>/dev/null)" || return 0
  PASS_HEAD="$(git rev-parse HEAD)" || return 0
  PASS_FILE="$store/$({ printf '%s\n' "$PASS_HEAD" "$PASS_GATE" "$@" "$cfg" "$me"; } | git hash-object --stdin)"
}

pass_reused() {  # a pass recorded under PASS_FILE answers for the gate
  local at; [ -n "$PASS_FILE" ] && [ -f "$PASS_FILE" ] && IFS=$'\t' read -r at _ < "$PASS_FILE" || return 1
  echo "$PASS_GATE: reused the pass on ${PASS_HEAD:0:12} recorded $at; nothing ran" >&2
}

pass_record() {  # after exit 0: one file per pass, renamed into place; records older than 14 days go
  [ -n "$PASS_FILE" ] || return 0
  local tmp="$PASS_FILE.$$.tmp"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PASS_HEAD" "$PASS_GATE" "$PASS_ARGS" > "$tmp" && mv "$tmp" "$PASS_FILE" || rm -f "$tmp"
  find "${PASS_FILE%/*}" -type f -mtime +14 -delete 2>/dev/null
  return 0
}

gate_build() {  # build <base>: answered by a recorded pass, else build_run
  require_rev "${1:-}"
  local main="${FACTORY_MAIN:-main}"
  pass_key build "$1" "$(git rev-parse "$1^{commit}")" "$(git rev-parse -q --verify "origin/$main^{commit}" 2>/dev/null)"
  pass_reused && return 0
  build_run "$1" && pass_record
}

build_run() {  # each implementer layer with changes runs its build from its own directory
  load_layers
  local files layer; files="$(changed_files "$1")"
  for layer in $IMPLEMENTERS; do
    layer_fields "$layer" _path_re path build install retry || exit 2
    [ -z "${LF[2]}" ] && continue
    printf '%s\n' "$files" | grep -Eq -- "${LF[0]}" || continue
    ensure_deps "${LF[1]}" "${LF[3]}" || exit 3
    (cd "$(root)/${LF[1]}" && bash -c "${LF[2]}") && continue
    # a layer with retry: 1 builds once more, as green does: a build that passes the second time broke on the machine
    # (a database that was slow to start, a worker that did not come up), not on the code
    if [ "${LF[4]:-0}" -ge 1 ] && (cd "$(root)/${LF[1]}" && bash -c "${LF[2]}"); then echo "flaky: $layer build"; continue; fi
    echo "build: $layer build failed" >&2; return 1
  done
}

gate_stack() {  # gate.sh stack up <owner> | down <owner> | status (lib/stack.sh)
  case "${1:-}" in
    up)     [ -n "${2:-}" ] || return 2; stack_up "$2" ;;
    down)   [ -n "${2:-}" ] || return 2; stack_down "$2" ;;
    status) stack_status ;;
    *) echo "stack: up <owner> | down <owner> | status" >&2; return 2 ;;
  esac
}

stack_around() {  # stack_around <command...>: run it on its own stack slot when the layer needs one; 3 = infrastructure
  [ "$L_STACK" = true ] || { "$@"; return; }
  local owner="gate-$$"
  local pid=""
  trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; stack_down "$owner"; exit 3' INT TERM  # exit still fires the EXIT verdict trap
  stack_up "$owner" >/dev/null || { trap - INT TERM; return 3; }  # not in a subshell: the slot's SHIPFLOOR_* stay exported for the runner
  "$@" & pid=$!  # in the background so a signal is handled while the runner runs
  wait "$pid"; local code=$?
  pid=""; trap - INT TERM
  stack_down "$owner"; return $code
}

run_selector() {  # run_selector <layer> <selector>: runner output; returns the runner's exit code
  # The selector reaches the runner as "$1" of `bash -c`, never as shell code.
  export NO_COLOR=1 FORCE_COLOR=0  # runners print plain text so the patterns below match
  local cmd="${L_TEST//\{selector\}/\"\$1\"}"
  (cd "$(root)/$L_PATH" 2>/dev/null || { echo "gate: layer directory $L_PATH not found"; exit 1; }; bash -c "$cmd" _ "$2" 2>&1)
}

load_layer() {  # load_layer <layer>: L_PATH L_TEST L_RAN L_ASSERT L_SETUP L_STACK L_RETRY, dependencies installed; 2 = unknown layer
  layer_fields "$1" path test ran assertions setup_errors needs_stack retry install || return 2
  L_PATH="${LF[0]}" L_TEST="${LF[1]}" L_RAN="${LF[2]}" L_ASSERT="${LF[3]}" L_SETUP="${LF[4]}" L_STACK="${LF[5]}" L_RETRY="${LF[6]:-0}"
  ensure_deps "$L_PATH" "${LF[7]}" || exit 3
  local p  # a pattern grep -E rejects reads as "no match" and could let red/green pass wrongly
  for p in "$L_RAN" "$L_ASSERT" "$L_SETUP"; do
    [ -z "$p" ] || ere_ok "$p" || { echo "gate: layer '$1' has an invalid grep -E pattern: $p" >&2; return 2; }
  done
}

SETUP_ERRORS='compilation (error|failure)|unresolved reference|cannot find module|syntaxerror|error TS[0-9]+|could not resolve|transform failed|is not a function|is not defined|ERR_CONNECTION|ECONNREFUSED|failed to load applicationcontext|beancreationexception|Errors: [1-9]|^ERROR: '
ASSERTIONS='AssertionFailedError|AssertionError|expected: ?<.*> but was|expect\(.*\)\.[A-Za-z]+\(.*\) failed|^[[:space:]]*Received:'

gate_red() {
  [ -z "${2:-}" ] && { echo "red: selector required" >&2; return 2; }
  load_layer "${1:-}" || return 2
  stack_around red_run "$1" "$2"
}

red_run() {  # red_run <layer> <selector>: never retried, a test that must fail cannot be flaky
  local layer="$1" sel="$2" out code setup assertions
  setup="$SETUP_ERRORS${L_SETUP:+|$L_SETUP}"; assertions="$ASSERTIONS${L_ASSERT:+|$L_ASSERT}"
  out="$(run_selector "$layer" "$sel")"; code=$?
  if [ "$code" -eq 0 ]; then echo "red: tests passed before implementation; they prove nothing" >&2; return 1; fi
  if printf '%s\n' "$out" | grep -Eiq -- "$setup"; then
    echo "red: tests fail for setup/compile reasons, not behavior:" >&2
    printf '%s\n' "$out" | grep -Ei -- "$setup" | head -5 >&2; return 1
  fi
  if ! printf '%s\n' "$out" | grep -Eq -- "$assertions"; then echo "red: no assertion failure found in test output" >&2; return 1; fi
  printf '%s\n' "$out" | grep -E -- "$assertions" | head -20
}

gate_green() {  # acceptance tests must run (the layer's `ran` pattern) and pass
  [ -z "${2:-}" ] && { echo "green: selector required" >&2; return 2; }
  pass_key green "${1:-} $2" "${1:-}" "$2"
  pass_reused && return 0
  load_layer "${1:-}" || return 2
  stack_around green_run "$1" "$2" && pass_record
}

green_run() {  # green_run <layer> <selector>: a layer with retry: 1 runs a failed selector once more
  local layer="$1" sel="$2" out code
  out="$(run_selector "$layer" "$sel")"; code=$?
  if [ "$code" -ne 0 ] && [ "${L_RETRY:-0}" -ge 1 ]; then
    out="$(run_selector "$layer" "$sel")"; code=$?
    [ "$code" -eq 0 ] && echo "flaky: $layer $sel"
  fi
  if [ "$code" -ne 0 ]; then echo "green: acceptance tests fail:" >&2; printf '%s\n' "$out" | tail -20 >&2; return 1; fi
  if ! printf '%s\n' "$out" | grep -Eq -- "$L_RAN"; then echo "green: no acceptance test ran for '$sel'" >&2; return 1; fi
}

cmd="${1:-}"; shift || true
run() {
  case "$cmd" in
    build)             gate_build "$@" ;;
    red)               gate_red "$@" ;;
    green)             gate_green "$@" ;;
    stack)             gate_stack "$@" ;;
    *) echo "gate-run: not a gate of this file: '$cmd'" >&2; exit 2 ;;
  esac
}
# what a gate says on stderr goes out in the project's language; stdout is read by callers and stays as it is
# shortcut: the key is read straight from the YAML (a top-level scalar the config check already validated), not through
# shipfloor_cfg: one more python start per gate call is what every pipeline step would pay
# A gate says its own verdict last, so a caller never needs `; echo $?` (headless runs refuse a `$` in a command).
# In a factory run it is also left in the run's lock (<lock>/last-gate): the dispatcher reads how a run ended from there,
# never from the agent's own report.
verdict() {  # verdict <exit code>
  local v=FAIL; case $1 in 0) v=pass; echo "gate $cmd: pass" >&2 ;; 3) v=INFRA; echo "gate $cmd: INFRA (exit 3)" >&2 ;; *) echo "gate $cmd: FAIL (exit $1)" >&2 ;; esac
  [ -n "${SHIPFLOOR_RUN_LOCK:-}" ] && [ -d "$SHIPFLOOR_RUN_LOCK" ] && printf '%s\t%s\n' "$cmd" "$v" > "$SHIPFLOOR_RUN_LOCK/last-gate" 2>/dev/null
  return 0
}
case "$cmd" in stack) ;; *) trap 'verdict $?' EXIT ;; esac
# The language a run started with (FACTORY_LANGUAGE, set at launch) wins; else this machine's overrides.yml, then factory.yml.
GLANG="${FACTORY_LANGUAGE:-}"; LANG_RE='^language:[[:space:]]*["'"'"']?([A-Za-z-]*)'
for GFILE in "${FACTORY_CONFIG%[/\\]*}/overrides.yml" "$FACTORY_CONFIG"; do
  [ -n "$GLANG" ] && break
  while IFS= read -r GLINE; do [[ "$GLINE" =~ $LANG_RE ]] && { GLANG="${BASH_REMATCH[1]}"; break; }; done 2>/dev/null < "$GFILE"
done
if [ "${GLANG:-en}" = en ]; then run "$@"; exit; fi
{ run "$@" 2>&1 1>&3 | shipfloor_say "$GLANG" >&2; exit "${PIPESTATUS[0]}"; } 3>&1
