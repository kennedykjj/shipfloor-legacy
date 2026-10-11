#!/usr/bin/env bash
# One dispatcher cycle for every project in ~/.aghanim/registry.tsv (slug, repo, worktrees, main).
# For each: bring its control checkout to origin/<main>, validate the config there, then run
# dispatch.sh for it. A project it cannot use is skipped and logged; the others still run.
set -uo pipefail
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.; HERE="$(cd "$HERE" && pwd)"  # no dirname: one process less per start
source "$HERE/lib/project.sh"
DISPATCH="${AGHANIM_DISPATCH:-$HERE/dispatch.sh}"
REGISTRY="$AGHANIM_HOME/registry.tsv"
[ -s "$REGISTRY" ] || exit 0

# One line of history per cycle, however it ends (logs/health-<month>.jsonl); it never fails the cycle.
START="$(date +%s)"; CYCLE="$AGHANIM_HOME/dispatch.pid"; OVERLAP=
# shortcut: a pid reused after a cycle died reads as a second cycle, once; use a lock dir if overlaps must also be prevented
if kill -0 "$(cat "$CYCLE" 2>/dev/null)" 2>/dev/null; then OVERLAP=--overlap; else echo $$ > "$CYCLE"; fi
health() {
  local rc=$?
  [ -n "$OVERLAP" ] || rm -f "$CYCLE"
  AGHANIM_BASH="$(aghanim_native "$BASH")" aghanim_python "$(aghanim_native "$HERE/aghanim_health.py")" record     --home "$(aghanim_native "$AGHANIM_HOME")" --seconds $(( $(date +%s) - START )) --exit "$rc" $OVERLAP >/dev/null 2>&1 || true
}
trap health EXIT
[ -e "$AGHANIM_HOME/PAUSE" ] && exit 0

usage_limited() {  # the Claude usage limit is per account: a recent hit in any project pauses all
  local f
  while IFS= read -r f; do
    awk '/^== start/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$f" | grep -q 'hit your session limit' && return 0
  done < <(find "$AGHANIM_HOME/projects" -path '*/logs/*.log' -mmin -30 2>/dev/null)
  return 1
}
MLANG="$(aghanim_machine values language 2>/dev/null | tr -d '\0')"  # the dispatcher's own log lines
usage_limited && { echo "$(date -Is) aghanim: Claude usage limit hit recently; waiting" | aghanim_say "$MLANG"; exit 0; }

STALE_LOCK_MIN="${AGHANIM_STALE_LOCK_MIN:-10}"
clear_stale_lock() {  # clear_stale_lock <checkout>: git holds index.lock for one command; an old one was left by a git that died
  local lock; lock="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)/index.lock"
  [ -e "$lock" ] && [ -n "$(find "$lock" -mmin +"$STALE_LOCK_MIN" 2>/dev/null)" ] || return 1
  rm -f "$lock" || return 1
  echo "$(date -Is) aghanim: $slug: removed a stale index.lock (older than $STALE_LOCK_MIN min): $lock" | aghanim_say "$MLANG" >&2
}

WHY=""  # why refresh_control failed: git's own words
refresh_control() {  # control checkout = exactly origin/<main>; touched only when main moved
  [ "${FACTORY_CONTROL_REFRESH:-1}" = "0" ] && return 0
  local c="$FACTORY_HOME/control" ref="origin/$FACTORY_MAIN" try err
  err="$(git -C "$FACTORY_REPO" fetch -q origin "$FACTORY_MAIN" 2>&1)" || { WHY="$err"; return 1; }
  if [ ! -e "$c/.git" ]; then
    mkdir -p "$FACTORY_HOME"
    err="$(git -C "$FACTORY_REPO" worktree add -q --detach "$c" "$ref" 2>&1)" || { WHY="$err"; return 1; }
  fi
  [ "$(git -C "$c" rev-parse HEAD 2>/dev/null)" = "$(git -C "$FACTORY_REPO" rev-parse "$ref")" ] && \
    [ -z "$(git -C "$c" status --porcelain 2>/dev/null)" ] && return 0
  # a pipeline running inside the control checkout may hold index.lock for a moment: retry;
  # a lock nobody can still hold is removed first
  for try in 1 2 3; do
    clear_stale_lock "$c"
    # core.longpaths: node_modules a run left behind passes Windows' 260 characters, and clean would fail on it
    err="$(git -C "$c" -c core.longpaths=true reset -q --hard "$ref" 2>&1 && git -C "$c" -c core.longpaths=true clean -qfdx 2>&1)" && return 0
    [ "$try" = 3 ] || sleep "${AGHANIM_LOCK_RETRY_S:-5}"
  done
  WHY="$err"; return 1
}

skip() {  # skip <reason>: log it and leave it in the project's home, where the dashboard and doctor look
  local f="$FACTORY_HOME/SKIPPED" since why
  why="$(printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g')"
  echo "$(date -Is) aghanim: $slug: $why; skipped" | aghanim_say "$MLANG" >&2
  mkdir -p "$FACTORY_HOME"
  since="$(cut -f1 "$f" 2>/dev/null | head -1)"  # the first failed cycle's time is kept
  printf '%s\t%s\n' "${since:-$(date -Is)}" "$why" > "$f"
  exit 1
}

status=0
while IFS=$'\t' read -r slug repo wt main <&3; do
  [ -z "$slug" ] && continue
  (
    aghanim_use "$slug" "$repo" "$wt" "$main"
    refresh_control || skip "cannot bring the control checkout to origin/$FACTORY_MAIN${WHY:+: $(printf '%s' "$WHY" | grep -m1 -E '^(fatal|error)' || printf '%s' "$WHY" | head -1)}"
    aghanim_snapshot || skip "no .aghanim/factory.yml on origin/$FACTORY_MAIN"
    aghanim_validate || skip "invalid .aghanim/factory.yml on origin/$FACTORY_MAIN"
    rm -f "$FACTORY_HOME/SKIPPED"
    FACTORY_CONTROL_REFRESH=0 bash "$DISPATCH"
  ) || status=1
done 3< "$REGISTRY"
exit $status
