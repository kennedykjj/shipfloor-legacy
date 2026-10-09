#!/usr/bin/env bash
# Deterministic gates for the factory pipelines.
# Exit 0 = pass, 1 = blocked (details on stderr), 2 = bad usage or bad revision (never a pass).
set -uo pipefail

# gate.sh -C <worktree> ...: run against that worktree (pipelines never `cd`).
if [ "${1:-}" = "-C" ]; then
  cd "${2:-}" 2>/dev/null || { echo "gate: cannot enter '${2:-}'" >&2; exit 2; }
  shift 2
fi

FORBIDDEN='^(\.github/|\.githooks/|\.claude/|scripts/factory/|docs/engineering/)|^(CLAUDE\.md|\.gitattributes|\.mcp\.json)$|(^|/)\.env'
TEST_CONFIG='^web/(vitest|playwright)\.config\.|^api/src/test/resources/junit-platform\.properties$'
MIGRATIONS='^api/src/main/resources/db/migration/V[^/]*__[^/]*\.sql$'
MVN="${FACTORY_MVN:-mvn}"
PNPM="${FACTORY_PNPM:-pnpm}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
g() { git -c core.quotePath=false "$@"; }

require_rev() {  # exits 2 unless $1 names a commit
  if [ -z "${1:-}" ] || ! git rev-parse --verify -q "$1^{commit}" >/dev/null; then
    echo "gate: bad revision '${1:-}'" >&2; exit 2
  fi
}

changed_files() {  # committed since base, uncommitted, and untracked
  local base="$1"
  { g diff --name-only --no-renames "$base" HEAD; g diff --name-only --no-renames HEAD; g ls-files --others --exclude-standard; } \
    | sed '/^$/d' | sort -u
}

gate_forbidden() {
  require_rev "${1:-}"
  local bad; bad="$(changed_files "$1" | grep -E "$FORBIDDEN" || true)"
  [ -z "$bad" ] && return 0
  echo "forbidden: these paths are off-limits to agents:" >&2; echo "$bad" >&2; return 1
}

gate_scope() {
  local role="${1:-}" base="${2:-}" allowed
  case "$role" in
    qa)       allowed='^(api/src/test/|web/e2e/)|^web/.*\.test\.tsx?$' ;;
    backend)  allowed='^api/' ;;
    frontend) allowed='^web/' ;;
    po|ux)    allowed='^docs/superpowers/specs/' ;;
    techlead) allowed='^docs/superpowers/(specs|plans)/' ;;
    *) echo "scope: unknown role '$role'" >&2; return 2 ;;
  esac
  require_rev "$base"
  local files bad; files="$(changed_files "$base")"
  bad="$(printf '%s\n' "$files" | sed '/^$/d' | grep -Ev "$allowed" || true)"
  if [ -n "$bad" ]; then echo "scope: $role touched files outside its area:" >&2; echo "$bad" >&2; return 1; fi
  case "$role" in backend|frontend)
    bad="$(printf '%s\n' "$files" | grep -E "$TEST_CONFIG" || true)"
    if [ -n "$bad" ]; then echo "scope: test runner config is off-limits to implementers:" >&2; echo "$bad" >&2; return 1; fi ;;
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

gate_migration() {
  require_rev "${1:-}"
  local base="$1" spec="${2:-}" destructive="" f
  while IFS= read -r f; do
    [[ "$f" =~ $MIGRATIONS ]] || continue
    if git cat-file -e "$base:$f" 2>/dev/null; then
      echo "migration: $f already exists on the base; applied migrations are immutable (add a new V<n>__ file)" >&2; return 1
    fi
    if grep -v '^[[:space:]]*--' "$f" | grep -Eiq '\b(drop|rename|truncate|delete)\b'; then destructive="$destructive $f"; fi
  done < <(changed_files "$base")
  [ -z "$destructive" ] && return 0
  local body; body="$(rollback_section "$spec" 2>/dev/null)"
  if [ -z "$body" ] || printf '%s' "$body" | grep -qi 'não se aplica'; then
    echo "migration: destructive migration(s)$destructive need a filled '## Rollback' section in $spec" >&2
    return 1
  fi
}

gate_build() {
  require_rev "${1:-}"
  local files; files="$(changed_files "$1")"
  if printf '%s\n' "$files" | grep -q '^api/'; then
    (cd "$ROOT/api" && "$MVN" -q test) || { echo "build: api tests failed" >&2; return 1; }
  fi
  if printf '%s\n' "$files" | grep -q '^web/'; then
    (cd "$ROOT/web" && "$PNPM" exec tsc --noEmit && "$PNPM" test) || { echo "build: web typecheck/tests failed" >&2; return 1; }
  fi
}

STACK_LOCK="${FACTORY_HOME:-$HOME/.pickio-factory}/locks/stack.lock"

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

run_selector() {  # run_selector <api|web|e2e> <selector>; prints output, returns the runner's exit code
  export NO_COLOR=1 FORCE_COLOR=0  # runners print plain text so the patterns below match
  if [ "$1" = e2e ] && [ -z "${FACTORY_STACK_HELD:-}" ]; then FACTORY_STACK_HELD=1 with_stack_lock run_selector "$@"; return; fi
  case "$1" in
    api) (cd "$ROOT/api" && "$MVN" test -Dtest="$2" -Dsurefire.failIfNoSpecifiedTests=true 2>&1) ;;
    web) (cd "$ROOT/web" && "$PNPM" exec vitest run "$2" 2>&1) ;;
    e2e) (cd "$ROOT/web" && "$PNPM" exec playwright test "$2" 2>&1) ;;
    *) echo "kind must be api|web|e2e"; return 2 ;;
  esac
}

SETUP_ERRORS='compilation (error|failure)|unresolved reference|cannot find module|syntaxerror|error TS[0-9]+|could not resolve|transform failed|is not a function|is not defined|ERR_CONNECTION|ECONNREFUSED|failed to load applicationcontext|beancreationexception|Errors: [1-9]|^ERROR: '
ASSERTIONS='AssertionFailedError|AssertionError|expected: ?<.*> but was|expect\(.*\)\.[A-Za-z]+\(.*\) failed|^[[:space:]]*Received:'

gate_red() {
  local kind="${1:-}" sel="${2:-}" out code
  [ -z "$sel" ] && { echo "red: selector required" >&2; return 2; }
  out="$(run_selector "$kind" "$sel")"; code=$?
  [ "$code" -eq 2 ] && [ "$out" = "kind must be api|web|e2e" ] && { echo "red: $out" >&2; return 2; }
  if [ "$code" -eq 0 ]; then echo "red: tests passed before implementation; they prove nothing" >&2; return 1; fi
  if printf '%s\n' "$out" | grep -Eiq "$SETUP_ERRORS"; then
    echo "red: tests fail for setup/compile reasons, not behavior:" >&2
    printf '%s\n' "$out" | grep -Ei "$SETUP_ERRORS" | head -5 >&2; return 1
  fi
  if ! printf '%s\n' "$out" | grep -Eq "$ASSERTIONS"; then echo "red: no assertion failure found in test output" >&2; return 1; fi
  printf '%s\n' "$out" | grep -E "$ASSERTIONS" | head -20
}

gate_green() {  # acceptance tests must run (more than zero) and pass
  local kind="${1:-}" sel="${2:-}" out code ran
  [ -z "$sel" ] && { echo "green: selector required" >&2; return 2; }
  out="$(run_selector "$kind" "$sel")"; code=$?
  case "$kind" in
    api) ran='Tests run: [1-9]' ;;
    web) ran='Tests +[1-9][0-9]* passed' ;;
    e2e) ran='(^|[[:space:]])[1-9][0-9]* passed' ;;
    *) echo "green: kind must be api|web|e2e" >&2; return 2 ;;
  esac
  if [ "$code" -ne 0 ]; then echo "green: acceptance tests fail:" >&2; printf '%s\n' "$out" | tail -20 >&2; return 1; fi
  if ! printf '%s\n' "$out" | grep -Eq "$ran"; then echo "green: no acceptance test ran for '$sel'" >&2; return 1; fi
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
