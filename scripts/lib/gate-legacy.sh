#!/usr/bin/env bash
# Deterministic gates for the factory pipelines.
# Exit 0 = pass, 1 = blocked (details on stderr), 2 = bad usage or bad revision (never a pass),
# 3 = infrastructure (the run's stack did not come up, or no stack slot in time).
set -uo pipefail

HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.; HERE="$(cd "$HERE/.." && pwd)"  # lib/'s parent; no dirname: one process less per start
# TEMPORARY (#165): the static gates the Python port has not taken over yet run here, as before; T4 deletes this file.
source "$HERE/lib/project.sh"
source "$HERE/lib/stack.sh"

# gate.sh -C <worktree> ...: run against that worktree (pipelines never `cd`).
if [ "${1:-}" = "-C" ]; then
  cd "${2:-}" 2>/dev/null || { echo "gate: cannot enter '${2:-}'" >&2; exit 2; }
  shift 2
fi

usage() {
  cat <<'EOF'
usage: gate.sh [-C <worktree>] <gate> ...
  test-plan <spec>                         every AC of the spec has a test its layer's runner can run
  weight <spec>                            the spec's header names one weight: light, standard or heavy
  scope <po|ux|techlead|qa|layer> <base>   only that role's files changed since <base>
  qa-commit <n> [--head]                   prints card <n>'s QA commit; --head: it must be the last commit
  qa-amend <n>                             QA's amendment of its own acceptance tests is honest
  acceptance-intact <qa>                   the acceptance tests are as QA committed them
  forbidden <base>                         no forbidden file changed since <base>
  migration <base> <spec>                  applied migrations untouched, destructive ones have a rollback
  build <base>                             each layer changed since <base> builds (reuses a pass recorded on this commit)
  red <layer> <selector>                   the tests fail on an assertion (before the implementation)
  green <layer> <selector>                 the tests ran and pass (reuses a pass recorded on this commit)
  stack up <owner> | down <owner> | status
<base> and <qa> are commits. Exit: 0 pass, 1 blocked, 2 bad usage or revision, 3 infrastructure.
A gate's last line on stderr is its verdict: "gate <name>: pass", "FAIL (exit 1)" or "INFRA (exit 3)".
In a factory run (SHIPFLOOR_RUN_LOCK), the verdict is also written to <lock>/last-gate for the dispatcher.
EOF
}
case "${1:-}" in -h|--help|help) usage; exit 0 ;; "") usage >&2; exit 2 ;; esac

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

odd_names() {  # 0 when a changed name has a control character (it could hide from the line-based checks)
  [ "$(raw_changes "$1" | LC_ALL=C tr -dc '\001-\037\177' | wc -c)" -gt 0 ]
}

changed_files() {  # one name per line (gate_forbidden refuses names with control characters)
  # gate_fast lists them once for its gates (CHANGED, the names since CHANGED_OF)
  if [ -n "${CHANGED_OF-}" ] && [ "$CHANGED_OF" = "$1" ]; then [ -z "$CHANGED" ] || printf '%s\n' "$CHANGED"; return 0; fi
  raw_changes "$1" | tr '\0' '\n' | sed '/^$/d' | sort -u
}

gate_forbidden() {
  require_rev "${1:-}"
  local forbidden bad; forbidden="${FAST[0]-$(q regex forbidden)}" || exit 2
  if odd_names "$1"; then echo "forbidden: a changed file name has a control character (newline, tab...)" >&2; return 1; fi
  bad="$(changed_files "$1" | grep -E -- "$forbidden" || true)"
  [ -z "$bad" ] && return 0
  echo "forbidden: these paths are off-limits to agents:" >&2; echo "$bad" >&2; return 1
}

gate_scope() {  # gate_scope <po|ux|techlead|qa|implementer layer> <base>
  local role="${1:-}" base="${2:-}" allowed
  [ -z "$role" ] && { echo "scope: role required" >&2; return 2; }
  allowed="$(shipfloor_cfg regex scope "$role" 2>/dev/null)" || { echo "scope: unknown role '$role'" >&2; return 2; }
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

main_bases() {  # main_bases <qa>: SIDE_M = the newest main commit merged into the card, SIDE_B = its common ancestor with QA; 1 = no main
  # The same for every file of a QA commit: found once, kept for the files and checks that follow in this shell.
  if [ "${SIDE_OF-}" != "$1" ]; then
    local main="" m
    SIDE_OF="$1" SIDE_M="" SIDE_B=""
    for m in "origin/${FACTORY_MAIN:-main}" "${FACTORY_MAIN:-main}"; do
      git rev-parse -q --verify "$m^{commit}" >/dev/null && { main="$m"; break; }
    done
    [ -z "$main" ] || SIDE_M="$(git merge-base HEAD "$main" 2>/dev/null)" || SIDE_M=""
    [ -z "$SIDE_M" ] || SIDE_B="$(git merge-base "$1" "$SIDE_M" 2>/dev/null)" || SIDE_M=""
  fi
  [ -n "$SIDE_M" ]
}

main_sides() {  # main_sides <qa> <file> <dir>: QA's version, main's and their common ancestor's, as <dir>/qa, main and base; 1 = main brought nothing
  local qa="$1" f="$2" m b
  main_bases "$qa" || return 1
  m="$SIDE_M" b="$SIDE_B"
  [ "$m" != "$b" ] && git cat-file -e "$m:$f" 2>/dev/null || return 1
  g show "$qa:$f" > "$3/qa" 2>/dev/null && g show "$m:$f" > "$3/main" && { g show "$b:$f" > "$3/base" 2>/dev/null || : > "$3/base"; }
}

merged_with_main() {  # merged_with_main <qa> <file> <out>: the file a clean merge gives, written to <out>; 1 = main brought nothing or the merge needs a hand
  # Acceptance tests often live in files main also edits. Rebuild the file a clean merge gives
  # (QA's version + main's version over their common ancestor).
  local tmp rc=1; tmp="$(mktemp -d)"
  main_sides "$1" "$2" "$tmp" && git merge-file -q "$tmp/qa" "$tmp/base" "$tmp/main" 2>/dev/null && cp "$tmp/qa" "$3" && rc=0
  rm -rf "$tmp"
  return $rc
}

both_sides_kept() {  # both_sides_kept <qa> <file>: a hand-resolved merge with main where HEAD is QA's version plus main's and nothing of its own
  # QA and main appending tests at the same spot conflict in git though neither loses a line. Passes when, blank lines aside:
  # the lines QA added and the lines main added are all in HEAD, each side's in its order; HEAD has no line that neither has;
  # and HEAD lacks no line of either, except one copy of a line both added (the same import).
  local tmp rc=1 x; tmp="$(mktemp -d)"
  if main_sides "$1" "$2" "$tmp" && g show "HEAD:$2" > "$tmp/head" 2>/dev/null; then
    for x in qa main base head; do grep -v '^[[:space:]]*$' "$tmp/$x" > "$tmp/$x.l"; done
    for x in qa main; do diff -d "$tmp/base.l" "$tmp/$x.l" | sed -n 's/^> //p' > "$tmp/$x.add"; LC_ALL=C sort "$tmp/$x.add" > "$tmp/$x.adds"; done
    cat "$tmp/qa.l" "$tmp/main.l" | LC_ALL=C sort > "$tmp/want"; cat "$tmp/head.l" "$tmp/base.l" | LC_ALL=C sort > "$tmp/got"
    ! diff -d "$tmp/qa.add" "$tmp/head.l" | grep -q '^<' && ! diff -d "$tmp/main.add" "$tmp/head.l" | grep -q '^<'       && [ -z "$(LC_ALL=C comm -13 "$tmp/want" "$tmp/got")" ]       && [ -z "$(LC_ALL=C comm -23 "$tmp/want" "$tmp/got" | LC_ALL=C comm -23 - <(LC_ALL=C comm -12 "$tmp/qa.adds" "$tmp/main.adds"))" ] && rc=0
  fi
  rm -rf "$tmp"
  return $rc
}

only_main_changed() {  # only_main_changed <qa> <file>: HEAD's file is the QA version plus what merges from main brought, nothing else
  # An edit by the card, or a merge that needed a hand resolution, differs from the clean merge.
  local tmp rc=1; tmp="$(mktemp)"
  merged_with_main "$1" "$2" "$tmp" && g show "HEAD:$2" 2>/dev/null | cmp -s - "$tmp" && rc=0
  rm -f "$tmp"; return $rc
}

own_edit() {  # own_edit <qa> <file>: the lines the card itself removed (<) or added (>), without what merges from main brought
  # Against the clean merge when there is one, else against QA's version: that diff is larger, so it only blocks more.
  local tmp; tmp="$(mktemp)"
  merged_with_main "$1" "$2" "$tmp" || g show "$1:$2" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  g show "HEAD:$2" 2>/dev/null | diff "$tmp" - | grep '^[<>]'  # diff exits 1 on a difference: the status says nothing
  rm -f "$tmp"; return 0
}

own_key() {  # own_key <qa> <file>: what shipfloor accept records for the card's own edit; a merge from main elsewhere in the file keeps it
  local own; own="$(own_edit "$1" "$2")" && [ -n "$own" ] || return 1
  echo "own:$(git hash-object --stdin <<< "$own")"
}

assertions_kept() {  # assertions_kept <qa> <file> <regex>: the card's own edits add or remove no line matching <regex> (acceptance_assertions)
  local own; [ -n "$3" ] || return 1
  own="$(own_edit "$1" "$2")" || return 1
  ! grep -Eq -- "$3" <<< "$own"
}

owner_accepted() {  # owner_accepted <file> [qa]: the owner reviewed the card's own edit, this exact content or its deletion, and recorded it (shipfloor accept)
  local blob own=""; [ -f "${FACTORY_HOME:-}/accepted.tsv" ] || return 1
  blob="$(git rev-parse -q --verify "HEAD:$1" 2>/dev/null)" || blob=deleted
  [ "$blob" = deleted ] || [ -z "${2:-}" ] || own="$(own_key "$2" "$1")"
  awk -F'\t' -v f="$1" -v b="$blob" -v o="$own" '$1 == f && ($2 == b || (o != "" && $2 == o)) { ok = 1 } END { exit !ok }' "$FACTORY_HOME/accepted.tsv"
}

qa_commits() {  # qa_commits <n> [rev]: card <n>'s QA commits up to rev, newest first (every "acceptance tests for #<n>")
  g log --format=%H -E --grep "acceptance tests for #$1([^0-9]|\$)" "${2:-HEAD}"
}

gate_acceptance_intact() {
  require_rev "${1:-}"
  local qa="$1" files changed keep n c
  keep="${FAST[2]-$(shipfloor_cfg get acceptance_assertions 2>/dev/null)}"
  # The newest QA commit is the baseline, but an amendment that touched one file must not leave the rest of the
  # card's acceptance tests unprotected: the files of every QA commit of the card count, as they are at the baseline.
  n="$(g log -1 --format=%s "$qa" | grep -oE 'acceptance tests for #[0-9]+' | grep -oE '[0-9]+$')"
  files="$({ g show --name-only --format= --diff-filter=d "$qa"  # files the QA commit deleted are not acceptance tests
             [ -z "$n" ] || for c in $(qa_commits "$n" "$qa"); do g show --name-only --format= --diff-filter=d "$c"; done; } |
           sort -u | while IFS= read -r f; do [ -z "$f" ] || ! git cat-file -e "$qa:$f" 2>/dev/null || echo "$f"; done)"
  [ -z "$files" ] && { echo "acceptance-intact: QA commit $qa has no files" >&2; return 1; }
  changed="$(printf '%s\n' "$files" | while IFS= read -r f; do
    if [ ! -e "$f" ] && ! git cat-file -e "HEAD:$f" 2>/dev/null; then owner_accepted "$f" || echo "$f"  # deleted and committed
    elif [ ! -e "$f" ] || ! git diff --quiet HEAD -- "$f"; then echo "$f"
    elif git diff --quiet "$qa" HEAD -- "$f" || only_main_changed "$qa" "$f" || both_sides_kept "$qa" "$f" || owner_accepted "$f" "$qa"; then :
    elif assertions_kept "$qa" "$f" "$keep"; then echo "acceptance-intact: $f changed, but no assertion line did (acceptance_assertions); passed" >&2
    else echo "$f"; fi
  done)"
  [ -z "$changed" ] && return 0
  echo "acceptance-intact: acceptance tests changed after the QA commit (beyond what merges from main brought):" >&2; echo "$changed" >&2
  echo "acceptance-intact: the owner can review these files and record them as they stand: shipfloor accept <project> <n> <reason>" >&2; return 1
}

# QA may correct its own acceptance tests when the implementation shows one was wrong, or when a merge from main
# reshaped a file they share: it commits again under the QA message and that commit becomes what acceptance-intact
# protects. Nobody reviews the amendment before the run goes on, so this gate keeps it honest: it is the last commit,
# it touches only tests, it loses no assertion line, it switches no test off, and a card is amended at most twice.
SKIP_MARKS='\.(skip|only|fixme|todo)\(|@Disabled|@Ignore|\b(xit|xdescribe|xtest)\(|\bt\.Skip\(|pytest\.mark\.skip'
gate_qa_amend() {  # qa-amend <n>
  [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "usage: gate.sh qa-amend <n>" >&2; exit 2; }
  local n="$1" all new prev allowed bad keep d lost gained off max="${FACTORY_QA_AMEND_MAX:-2}" fs
  all="$(qa_commits "$n")"; new="$(sed -n 1p <<< "$all")"; prev="$(sed -n 2p <<< "$all")"
  if [ -z "$new" ] || [ "$new" != "$(g rev-parse HEAD)" ]; then echo "qa-amend: the last commit is not a QA commit (\"acceptance tests for #$n\")" >&2; return 1; fi
  [ -n "$prev" ] || { echo "qa-amend: #$n has one QA commit, so nothing was amended" >&2; return 1; }
  if [ "$(grep -c . <<< "$all")" -gt $((max + 1)) ]; then
    echo "qa-amend: the acceptance tests of #$n were already amended $max times; the owner decides now" >&2; return 1; fi
  allowed="$(q regex scope qa)" || exit 2
  bad="$(g show --name-only --format= "$new" | sed '/^$/d' | grep -Ev -- "$allowed" || true)"
  if [ -n "$bad" ]; then echo "qa-amend: the amendment touches files that are not tests:" >&2; echo "$bad" >&2; return 1; fi
  keep="$(shipfloor_cfg get acceptance_assertions 2>/dev/null)"; keep="${keep:-assert|expect\(|verify\(|should}"
  mapfile -t fs < <(for c in $all; do g show --name-only --format= "$c"; done | sed '/^$/d' | sort -u)
  d="$(g diff -U0 "$prev" "$new" -- "${fs[@]}" | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---) ' || true)"
  off="$(grep -E '^\+' <<< "$d" | grep -E -- "$SKIP_MARKS" || true)"
  if [ -n "$off" ]; then echo "qa-amend: the amendment switches a test off:" >&2; echo "$off" >&2; return 1; fi
  lost="$(grep -E '^-' <<< "$d" | grep -Ec -- "$keep" || true)"; gained="$(grep -E '^\+' <<< "$d" | grep -Ec -- "$keep" || true)"
  if [ "$gained" -lt "$lost" ]; then
    echo "qa-amend: the amendment removes $lost assertion lines and adds $gained; an amended test may check differently, not less" >&2; return 1; fi
  echo "qa-amend: ok, $lost assertion lines replaced by $gained" >&2
}

gate_qa_commit() {  # qa-commit <n> [--head]: prints card <n>'s QA commit, the newest "acceptance tests for #<n>" on the branch
  # Every stage asks here, so a rework's QA commit replaces the first one for all of them. --head: it must be the last commit.
  [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "usage: gate.sh qa-commit <n> [--head]" >&2; exit 2; }
  local qa; qa="$(g log --format=%H -1 -E --grep "acceptance tests for #$1([^0-9]|\$)")"
  if [ -z "$qa" ] || { [ "${2:-}" = --head ] && [ "$qa" != "$(g rev-parse HEAD)" ]; }; then
    echo "qa-commit: ${2:+the last commit is not the QA commit: }no commit message with \"acceptance tests for #$1\"${2:+ at HEAD}" >&2; return 1
  fi
  echo "$qa"
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
  } | shipfloor_cfg migration-check "$layer" \
    || { echo "migration: versions of layer '$layer' must be unique and newer than the base's" >&2; return 1; }
}

gate_migration() {  # every layer's migrations: applied ones are immutable, destructive ones need a rollback
  require_rev "${1:-}"
  local base="$1" spec="${2:-}" destructive="" f layer re comment files plan
  # the order check trusts the base: it must be on this branch's history
  git merge-base --is-ancestor "$base" HEAD 2>/dev/null || { echo "migration: base $base is not an ancestor of HEAD" >&2; exit 2; }
  plan="${FAST[1]-$(q migration-layers)}" || exit 2  # first line: main branch; then <layer> <ERE> <comment prefix>
  MAIN="$(printf '%s\n' "$plan" | head -1)"
  files="$(changed_files "$base")"
  while IFS=$'\t' read -r layer re comment; do
    [ -z "$layer" ] && continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      printf '%s\n' "$f" | grep -Eq -- "$re" || continue
      if git cat-file -e "$base:$f" 2>/dev/null; then
        echo "migration: $f already exists on the base; applied migrations are immutable (add a new file)" >&2; return 1
      fi
      [ -f "$f" ] || continue
      if code_lines "$f" "$comment" | grep -Eiq '\b(drop|rename|truncate|delete)\b'; then destructive="$destructive $f"; fi
    done <<< "$files"
    migration_versions "$layer" "$base" "$re" || return 1
  done < <(printf '%s\n' "$plan" | tail -n +2)
  [ -z "$destructive" ] && return 0
  local body; body="$(rollback_section "$spec" 2>/dev/null)"
  if [ -z "$body" ] || printf '%s' "$body" | grep -Eqi 'não se aplica|^[-* ]*(n/a|none|not applicable)[. ]*$'; then
    echo "migration: destructive migration(s)$destructive need a filled '## Rollback' section in $spec" >&2
    return 1
  fi
}

gate_fast() {  # gate_fast <base> <spec> [qa]: forbidden + migration + acceptance-intact in one process
  # one config start for the three (FAST: forbidden ERE, migration plan, acceptance_assertions); alone, each gate asks for its own
  mapfile -d '' -t FAST < <(shipfloor_cfg gate-fast)
  [ "${#FAST[@]}" -eq 3 ] || { echo "gate: config query failed: gate-fast" >&2; exit 2; }
  require_rev "${1:-}"
  CHANGED="$(changed_files "$1")"; CHANGED_OF="$1"
  gate_forbidden "$1" || return $?
  gate_migration "$1" "${2:-}" || return $?
  [ -z "${3:-}" ] || gate_acceptance_intact "$3"
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
    printf '%s
' "$files" | grep -Eq -- "${LF[0]}" || continue
    ensure_deps "${LF[1]}" "${LF[3]}" || exit 3
    (cd "$(root)/${LF[1]}" && bash -c "${LF[2]}") && continue
    # a layer with retry: 1 builds once more, as green does: a build that passes the second time broke on the machine
    # (a database that was slow to start, a worker that did not come up), not on the code
    if [ "${LF[4]:-0}" -ge 1 ] && (cd "$(root)/${LF[1]}" && bash -c "${LF[2]}"); then echo "flaky: $layer build"; continue; fi
    echo "build: $layer build failed" >&2; return 1
  done
}

test_plan_rows() {  # test_plan_rows <spec>: "<ACs>\t<layer>\t<first `path` of the file cell>" per table row
  awk -F'|' '/^## /{on=($0 ~ /^## Test plan/); next}
    on && /^[[:space:]]*\|/ && $2 !~ /^[[:space:]]*AC[[:space:]]*$/ && $2 !~ /^[[:space:]:-]*$/ {
      ac=$2; layer=$3; file=$4; gsub(/^[[:space:]]+|[[:space:]]+$/, "", layer)
      path=""; if (match(file, /`[^`]+`/)) path=substr(file, RSTART+1, RLENGTH-2)
      print ac "\t" layer "\t" path }' "$1"
}

gate_test_plan() {  # every AC in the spec has a row whose test file its layer's runner can run
  load_layers
  local spec="${1:-}"
  [ -f "$spec" ] || { echo "test-plan: spec '${spec}' not found" >&2; return 2; }
  local rows bad="" ac acs layer path
  rows="$(test_plan_rows "$spec")"
  [ -z "$rows" ] && { echo "test-plan: '## Test plan' has no rows in $spec" >&2; return 1; }
  while IFS=$'\t' read -r acs layer path; do
    [ "$layer" = manual ] && continue  # checked by hand in review
    if ! printf '%s\n' $ALL_LAYERS | grep -qxF -- "$layer"; then
      bad="$bad\n$acs: unknown layer '$layer' (layers: $(echo $ALL_LAYERS), or manual)"; continue
    fi
    layer_fields "$layer" _tests_re || exit 2
    if [ -z "$path" ] || ! printf '%s\n' "$path" | grep -Eq -- "${LF[0]}"; then
      bad="$bad\n$acs: '${path:-no path}' is not a test file of layer '$layer' (its tests: $(q layer "$layer" tests | tr '\n' ' '))"
    fi
  done <<< "$rows"
  for ac in $(grep -oE '\bAC-[0-9]+\b' <(awk '/^## /{on=($0 ~ /^## Product/); next} on' "$spec") | sort -u); do
    printf '%s\n' "$rows" | cut -f1 | grep -qE -- "\b$ac\b" || bad="$bad\n$ac: no row in '## Test plan'"
  done
  [ -z "$bad" ] && return 0
  echo "test-plan: the pipeline cannot run these acceptance tests (paths are repo-relative):" >&2
  printf '%b\n' "${bad#\\n}" >&2; return 1
}

gate_weight() {  # weight <spec>: exactly one "**Weight:** light|standard|heavy" line before the first "## "
  local spec="${1:-}" lines
  [ -f "$spec" ] || { echo "weight: spec '${spec}' not found" >&2; return 2; }
  lines="$(awk '/^## /{exit} /^\*\*Weight:\*\*/' "$spec" | tr -d '\r')"
  if [ -z "$lines" ]; then echo "weight: the spec header has no '**Weight:** light|standard|heavy' line ($spec)" >&2; return 1; fi
  if [ "$(printf '%s\n' "$lines" | wc -l)" -gt 1 ]; then echo "weight: the spec header has more than one weight line:" >&2; printf '%s\n' "$lines" >&2; return 1; fi
  [[ "$lines" =~ ^\*\*Weight:\*\*[[:space:]]*\`?(light|standard|heavy)\`?[[:space:]]*$ ]] && return 0
  echo "weight: '$lines' names no weight the factory knows (light, standard, heavy)" >&2; return 1
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
  if [ "$code" -ne 0 ]; then echo "green: acceptance tests fail:" >&2; printf '%s
' "$out" | tail -20 >&2; return 1; fi
  if ! printf '%s
' "$out" | grep -Eq -- "$L_RAN"; then echo "green: no acceptance test ran for '$sel'" >&2; return 1; fi
}

cmd="${1:-}"; shift || true
run() {
  case "$cmd" in
    scope)             gate_scope "$@" ;;
    forbidden)         gate_forbidden "$@" ;;
    acceptance-intact) gate_acceptance_intact "$@" ;;
    acceptance-own)    require_rev "${1:-}"; own_key "$1" "${2:-}" ;;  # for shipfloor accept
    qa-commit)         gate_qa_commit "$@" ;;
    qa-amend)          gate_qa_amend "$@" ;;
    migration)         gate_migration "$@" ;;
    fast)              gate_fast "$@" ;;
    build)             gate_build "$@" ;;
    red)               gate_red "$@" ;;
    green)             gate_green "$@" ;;
    test-plan)         gate_test_plan "$@" ;;
    weight)            gate_weight "$@" ;;
    stack)             gate_stack "$@" ;;
    *) usage >&2; exit 2 ;;
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
case "$cmd" in acceptance-own|stack) ;; *) trap 'verdict $?' EXIT ;; esac
# The language a run started with (FACTORY_LANGUAGE, set at launch) wins; else this machine's overrides.yml, then factory.yml.
GLANG="${FACTORY_LANGUAGE:-}"; LANG_RE='^language:[[:space:]]*["'"'"']?([A-Za-z-]*)'
for GFILE in "${FACTORY_CONFIG%[/\\]*}/overrides.yml" "$FACTORY_CONFIG"; do
  [ -n "$GLANG" ] && break
  while IFS= read -r GLINE; do [[ "$GLINE" =~ $LANG_RE ]] && { GLANG="${BASH_REMATCH[1]}"; break; }; done 2>/dev/null < "$GFILE"
done
if [ "${GLANG:-en}" = en ]; then run "$@"; exit; fi
{ run "$@" 2>&1 1>&3 | shipfloor_say "$GLANG" >&2; exit "${PIPESTATUS[0]}"; } 3>&1
