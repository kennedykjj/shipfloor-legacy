#!/usr/bin/env bash
# Deterministic gates for the factory pipelines.
# Exit 0 = pass, 1 = blocked (details on stderr), 2 = bad usage or bad revision (never a pass).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/project.sh"

# gate.sh -C <worktree> ...: run against that worktree (pipelines never `cd`).
if [ "${1:-}" = "-C" ]; then
  cd "${2:-}" 2>/dev/null || { echo "gate: cannot enter '${2:-}'" >&2; exit 2; }
  shift 2
fi

# Paths, layers and commands come from the project's config (its control checkout), never from
# the worktree under test. No project or a broken config is exit 2, never a pass.
mylos_resolve . || exit 2
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
g() { git -c core.quotePath=false "$@"; }
q() {  # q <query...>: one config answer; a failing query stops the gate with exit 2
  local out; out="$(mylos_cfg "$@")" || { echo "gate: config query failed: $*" >&2; exit 2; }
  printf '%s' "$out"
}
layer_fields() {  # layer_fields <layer> <field>...: values into the array LF; 2 = unknown layer
  LF=()
  mapfile -d '' -t LF < <(mylos_cfg fields "$@" 2>/dev/null)
  [ "${#LF[@]}" -eq $(( $# - 1 )) ] || { echo "gate: unknown layer '$1'" >&2; return 2; }
}
IMPLEMENTERS="$(q layers --implementers)" || exit 2
ALL_LAYERS="$(q layers)" || exit 2

require_rev() {  # exits 2 unless $1 names a commit
  if [ -z "${1:-}" ] || ! git rev-parse --verify -q "$1^{commit}" >/dev/null; then
    echo "gate: bad revision '${1:-}'" >&2; exit 2
  fi
}

raw_changes() {  # NUL-separated names: committed since base, uncommitted, and untracked (never C-quoted)
  g diff -z --name-only --no-renames "$1" HEAD; g diff -z --name-only --no-renames HEAD; g ls-files -z --others --exclude-standard
}

odd_names() {  # 0 when a changed name has a control character (it could hide from the line-based checks)
  [ "$(raw_changes "$1" | LC_ALL=C tr -dc '\001-\037\177' | wc -c)" -gt 0 ]
}

changed_files() {  # one name per line (gate_forbidden refuses names with control characters)
  raw_changes "$1" | tr '\0' '\n' | sed '/^$/d' | sort -u
}

gate_forbidden() {
  require_rev "${1:-}"
  local forbidden bad; forbidden="$(q regex forbidden)" || exit 2
  if odd_names "$1"; then echo "forbidden: a changed file name has a control character (newline, tab...)" >&2; return 1; fi
  bad="$(changed_files "$1" | grep -E -- "$forbidden" || true)"
  [ -z "$bad" ] && return 0
  echo "forbidden: these paths are off-limits to agents:" >&2; echo "$bad" >&2; return 1
}

gate_scope() {  # gate_scope <po|ux|techlead|qa|implementer layer> <base>
  local role="${1:-}" base="${2:-}" allowed
  [ -z "$role" ] && { echo "scope: role required" >&2; return 2; }
  allowed="$(mylos_cfg regex scope "$role" 2>/dev/null)" || { echo "scope: unknown role '$role'" >&2; return 2; }
  [ -n "$allowed" ] || { echo "scope: role '$role' has no area in the config" >&2; return 2; }
  require_rev "$base"
  local files bad; files="$(changed_files "$base")"
  bad="$(printf '%s
' "$files" | sed '/^$/d' | grep -Ev -- "$allowed" || true)"
  if [ -n "$bad" ]; then echo "scope: $role touched files outside its area:" >&2; echo "$bad" >&2; return 1; fi
  case "$role" in po|ux|techlead|qa) ;; *)
    local test_config; test_config="$(q regex test-config)" || exit 2
    if [ -n "$test_config" ]; then
      bad="$(printf '%s
' "$files" | grep -E -- "$test_config" || true)"
      if [ -n "$bad" ]; then echo "scope: test runner config is off-limits to implementers:" >&2; echo "$bad" >&2; return 1; fi
    fi
    local qa_only; qa_only="$(q regex tests-only)" || exit 2
    if [ -n "$qa_only" ]; then
      bad="$(printf '%s\n' "$files" | grep -E -- "$qa_only" || true)"
      if [ -n "$bad" ]; then echo "scope: only QA writes in tests-only layers:" >&2; echo "$bad" >&2; return 1; fi
    fi ;;
  esac
  gate_forbidden "$base"
}

gate_acceptance_intact() {
  require_rev "${1:-}"
  local qa="$1" files changed
  files="$(g show --name-only --format= --diff-filter=d "$qa")"  # files the QA commit deleted are not acceptance tests
  [ -z "$files" ] && { echo "acceptance-intact: QA commit $qa has no files" >&2; return 1; }
  changed="$(printf '%s\n' "$files" | while IFS= read -r f; do
    if [ ! -e "$f" ] || ! git diff --quiet "$qa" HEAD -- "$f" || ! git diff --quiet HEAD -- "$f"; then echo "$f"; fi
  done)"
  [ -z "$changed" ] && return 0
  echo "acceptance-intact: acceptance tests changed after the QA commit:" >&2; echo "$changed" >&2; return 1
}

rollback_section() {  # body of '## Rollback', without HTML comments and blank lines
  awk '/^## /{on=($0 ~ /^## Rollback/); next} on' "$1" | sed 's/<!--.*-->//g' | sed '/^[[:space:]]*$/d'
}

code_lines() {  # code_lines <file> <comment prefix>: lines that are not comments
  awk -v c="$2" '{ s = $0; sub(/^[[:space:]]+/, "", s); if (c == "" || index(s, c) != 1) print }' "$1"
}

migration_versions() {  # migration_versions <layer> <base> <ERE>: unique versions, new ones after every existing one
  # E = on the base or on origin/<main> (merged, maybe applied); N = the card's own. Parallel cards
  # collide here, even before the card merges main: origin/<main> is read directly.
  local layer="$1" base="$2" re="$3" main_ref="" rev
  git rev-parse -q --verify "origin/$MAIN^{commit}" >/dev/null && main_ref="origin/$MAIN"
  {
    for rev in "$base" $main_ref; do
      g ls-tree -r -z --name-only "$rev" | tr '\0' '\n' | grep -E -- "$re"
    done | sort -u | sed 's/^/E\t/'
    { g ls-files -z; g ls-files -z --others --exclude-standard; } | tr '\0' '\n' | sort -u | grep -E -- "$re" \
      | while IFS= read -r f; do
          [ -f "$f" ] || continue
          git cat-file -e "$base:$f" 2>/dev/null && continue
          [ -n "$main_ref" ] && git cat-file -e "$main_ref:$f" 2>/dev/null && continue
          printf 'N\t%s\n' "$f"
        done
  } | mylos_cfg migration-check "$layer" \
    || { echo "migration: versions of layer '$layer' must be unique and newer than the base's" >&2; return 1; }
}

gate_migration() {  # every layer's migrations: applied ones are immutable, destructive ones need a rollback
  require_rev "${1:-}"
  local base="$1" spec="${2:-}" destructive="" f layer files
  # the order check trusts the base: it must be on this branch's history
  git merge-base --is-ancestor "$base" HEAD 2>/dev/null || { echo "migration: base $base is not an ancestor of HEAD" >&2; exit 2; }
  MAIN="$(q get project.main)" || exit 2
  files="$(changed_files "$base")"
  for layer in $ALL_LAYERS; do
    layer_fields "$layer" _migrations_re migrations.comment || exit 2
    [ -z "${LF[0]}" ] && continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      printf '%s
' "$f" | grep -Eq -- "${LF[0]}" || continue
      if git cat-file -e "$base:$f" 2>/dev/null; then
        echo "migration: $f already exists on the base; applied migrations are immutable (add a new file)" >&2; return 1
      fi
      [ -f "$f" ] || continue
      if code_lines "$f" "${LF[1]}" | grep -Eiq '\b(drop|rename|truncate|delete)\b'; then destructive="$destructive $f"; fi
    done <<< "$files"
    migration_versions "$layer" "$base" "${LF[0]}" || return 1
  done
  [ -z "$destructive" ] && return 0
  local body; body="$(rollback_section "$spec" 2>/dev/null)"
  if [ -z "$body" ] || printf '%s' "$body" | grep -Eqi 'não se aplica|^[-* ]*(n/a|none|not applicable)[. ]*$'; then
    echo "migration: destructive migration(s)$destructive need a filled '## Rollback' section in $spec" >&2
    return 1
  fi
}

gate_build() {  # each implementer layer with changes runs its build from its own directory
  require_rev "${1:-}"
  local files layer; files="$(changed_files "$1")"
  for layer in $IMPLEMENTERS; do
    layer_fields "$layer" _path_re path build || exit 2
    [ -z "${LF[2]}" ] && continue
    printf '%s
' "$files" | grep -Eq -- "${LF[0]}" || continue
    (cd "$ROOT/${LF[1]}" && bash -c "${LF[2]}") || { echo "build: $layer build failed" >&2; return 1; }
  done
}

STACK_LOCK="${FACTORY_HOME:-$MYLOS_HOME}/locks/stack.lock"

# The one local stack (Docker, port 3000) is used by e2e and verify-ui; parallel pipelines queue on
# stack.lock. info = "<owner> <epoch>"; a lock older than STACK_TTL is abandoned and gets reclaimed.
STACK_TTL="${FACTORY_STACK_TTL:-2700}"

stack_acquire() {  # stack_acquire <owner>
  local owner="$1" waited=0 max="${FACTORY_STACK_WAIT:-1800}" held epoch
  mkdir -p "$(dirname "$STACK_LOCK")"
  until mkdir "$STACK_LOCK" 2>/dev/null; do
    read -r held epoch _ < "$STACK_LOCK/info" 2>/dev/null || read -r held _ < "$STACK_LOCK/owner" 2>/dev/null || true
    [ -z "${epoch:-}" ] && epoch="$(stat -c %Y "$STACK_LOCK" 2>/dev/null || date +%s)"
    if [ $(( $(date +%s) - epoch )) -gt "$STACK_TTL" ]; then rm -rf "$STACK_LOCK"; continue; fi
    [ "${held:-}" = "$owner" ] && return 0
    [ "$waited" -ge "$max" ] && { echo "stack busy (held by ${held:-?}) for ${max}s; try again later" >&2; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  echo "$owner $(date +%s)" > "$STACK_LOCK/info"
}

stack_release() {  # stack_release <owner>: only the owner releases
  local held; read -r held _ < "$STACK_LOCK/info" 2>/dev/null || read -r held _ < "$STACK_LOCK/owner" 2>/dev/null || return 0
  [ "$held" = "$1" ] && rm -rf "$STACK_LOCK"
  return 0
}

with_stack_lock() {  # run a command holding the stack lock
  local owner="gate-$$"
  stack_acquire "$owner" || { echo "stack busy; try again later"; return 1; }
  "$@"; local code=$?
  stack_release "$owner"; return $code
}

gate_stack_lock() {  # gate.sh stack-lock acquire|release <owner>
  case "${1:-}" in
    acquire) [ -n "${2:-}" ] || return 2; stack_acquire "$2" ;;
    release) [ -n "${2:-}" ] || return 2; stack_release "$2" ;;
    *) echo "stack-lock: acquire|release <owner>" >&2; return 2 ;;
  esac
}

run_selector() {  # run_selector <layer> <selector>: runner output; returns the runner's exit code
  # The selector reaches the runner as "$1" of `bash -c`, never as shell code.
  export NO_COLOR=1 FORCE_COLOR=0  # runners print plain text so the patterns below match
  if [ "$L_STACK" = true ] && [ -z "${FACTORY_STACK_HELD:-}" ]; then FACTORY_STACK_HELD=1 with_stack_lock run_selector "$@"; return; fi
  local cmd="${L_TEST//\{selector\}/\"\$1\"}"
  (cd "$ROOT/$L_PATH" 2>/dev/null || { echo "gate: layer directory $L_PATH not found"; exit 1; }; bash -c "$cmd" _ "$2" 2>&1)
}

load_layer() {  # load_layer <layer>: L_PATH L_TEST L_RAN L_ASSERT L_SETUP L_STACK; 2 = unknown layer
  layer_fields "$1" path test ran assertions setup_errors needs_stack || return 2
  L_PATH="${LF[0]}" L_TEST="${LF[1]}" L_RAN="${LF[2]}" L_ASSERT="${LF[3]}" L_SETUP="${LF[4]}" L_STACK="${LF[5]}"
  local p  # a pattern grep -E rejects reads as "no match" and could let red/green pass wrongly
  for p in "$L_RAN" "$L_ASSERT" "$L_SETUP"; do
    [ -z "$p" ] || ere_ok "$p" || { echo "gate: layer '$1' has an invalid grep -E pattern: $p" >&2; return 2; }
  done
}

SETUP_ERRORS='compilation (error|failure)|unresolved reference|cannot find module|syntaxerror|error TS[0-9]+|could not resolve|transform failed|is not a function|is not defined|ERR_CONNECTION|ECONNREFUSED|failed to load applicationcontext|beancreationexception|Errors: [1-9]|^ERROR: '
ASSERTIONS='AssertionFailedError|AssertionError|expected: ?<.*> but was|expect\(.*\)\.[A-Za-z]+\(.*\) failed|^[[:space:]]*Received:'

gate_red() {
  local layer="${1:-}" sel="${2:-}" out code setup assertions
  [ -z "$sel" ] && { echo "red: selector required" >&2; return 2; }
  load_layer "$layer" || return 2
  setup="$SETUP_ERRORS${L_SETUP:+|$L_SETUP}"; assertions="$ASSERTIONS${L_ASSERT:+|$L_ASSERT}"
  out="$(run_selector "$layer" "$sel")"; code=$?
  if [ "$code" -eq 0 ]; then echo "red: tests passed before implementation; they prove nothing" >&2; return 1; fi
  if printf '%s
' "$out" | grep -Eiq -- "$setup"; then
    echo "red: tests fail for setup/compile reasons, not behavior:" >&2
    printf '%s
' "$out" | grep -Ei -- "$setup" | head -5 >&2; return 1
  fi
  if ! printf '%s
' "$out" | grep -Eq -- "$assertions"; then echo "red: no assertion failure found in test output" >&2; return 1; fi
  printf '%s
' "$out" | grep -E -- "$assertions" | head -20
}

gate_green() {  # acceptance tests must run (the layer's `ran` pattern) and pass
  local layer="${1:-}" sel="${2:-}" out code
  [ -z "$sel" ] && { echo "green: selector required" >&2; return 2; }
  load_layer "$layer" || return 2
  out="$(run_selector "$layer" "$sel")"; code=$?
  if [ "$code" -ne 0 ]; then echo "green: acceptance tests fail:" >&2; printf '%s
' "$out" | tail -20 >&2; return 1; fi
  if ! printf '%s
' "$out" | grep -Eq -- "$L_RAN"; then echo "green: no acceptance test ran for '$sel'" >&2; return 1; fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  scope)             gate_scope "$@" ;;
  forbidden)         gate_forbidden "$@" ;;
  acceptance-intact) gate_acceptance_intact "$@" ;;
  migration)         gate_migration "$@" ;;
  build)             gate_build "$@" ;;
  red)               gate_red "$@" ;;
  green)             gate_green "$@" ;;
  stack-lock)        gate_stack_lock "$@" ;;
  *) echo "usage: gate.sh scope|forbidden|acceptance-intact|migration|build|red|green ..." >&2; exit 2 ;;
esac
