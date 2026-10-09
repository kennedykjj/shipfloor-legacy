#!/usr/bin/env bash
# One dispatcher cycle for every project in ~/.mylos/registry.tsv (slug, repo, worktrees, main).
# For each: bring its control checkout to origin/<main>, validate the config there, then run
# dispatch.sh for it. A project it cannot use is skipped and logged; the others still run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/project.sh"
DISPATCH="${MYLOS_DISPATCH:-$HERE/dispatch.sh}"
REGISTRY="$MYLOS_HOME/registry.tsv"
[ -e "$MYLOS_HOME/PAUSE" ] && exit 0
[ -s "$REGISTRY" ] || exit 0

usage_limited() {  # the Claude usage limit is per account: a recent hit in any project pauses all
  local f
  while IFS= read -r f; do
    awk '/^== start/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$f" | grep -q 'hit your session limit' && return 0
  done < <(find "$MYLOS_HOME/projects" -path '*/logs/*.log' -mmin -30 2>/dev/null)
  return 1
}
usage_limited && { echo "$(date -Is) mylos: Claude usage limit hit recently; waiting"; exit 0; }

refresh_control() {  # control checkout = exactly origin/<main>; touched only when main moved
  [ "${FACTORY_CONTROL_REFRESH:-1}" = "0" ] && return 0
  local c="$FACTORY_HOME/control" ref="origin/$FACTORY_MAIN" try
  git -C "$FACTORY_REPO" fetch -q origin "$FACTORY_MAIN" || return 1
  if [ ! -e "$c/.git" ]; then mkdir -p "$FACTORY_HOME"; git -C "$FACTORY_REPO" worktree add -q --detach "$c" "$ref" || return 1; fi
  [ "$(git -C "$c" rev-parse HEAD 2>/dev/null)" = "$(git -C "$FACTORY_REPO" rev-parse "$ref")" ] && \
    [ -z "$(git -C "$c" status --porcelain 2>/dev/null)" ] && return 0
  # a pipeline running inside the control checkout may hold index.lock for a moment: retry
  for try in 1 2 3; do
    git -C "$c" reset -q --hard "$ref" && git -C "$c" clean -qfdx && return 0
    [ "$try" = 3 ] || sleep 5
  done
  return 1
}

status=0
while IFS=$'\t' read -r slug repo wt main <&3; do
  [ -z "$slug" ] && continue
  (
    mylos_use "$slug" "$repo" "$wt" "$main"
    refresh_control || { echo "$(date -Is) mylos: $slug: cannot bring the control checkout to origin/$FACTORY_MAIN; skipped" >&2; exit 1; }
    mylos_snapshot || { echo "$(date -Is) mylos: $slug: no .mylos/factory.yml on origin/$FACTORY_MAIN; skipped" >&2; exit 1; }
    mylos_validate || { echo "$(date -Is) mylos: $slug: invalid .mylos/factory.yml on origin/$FACTORY_MAIN; skipped" >&2; exit 1; }
    FACTORY_CONTROL_REFRESH=0 bash "$DISPATCH"
  ) || status=1
done 3< "$REGISTRY"
exit $status
