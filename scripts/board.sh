#!/usr/bin/env bash
# Reads and moves cards on the project's board (a GitHub Project v2, from .mylos/factory.yml).
set -uo pipefail
source "$(dirname "$0")/lib/project.sh"
GH="${FACTORY_GH:-gh}"
aghanim_resolve . || exit 2
mapfile -d '' -t V < <(aghanim_cfg values board.owner board.number project.repo 2>/dev/null)
[ "${#V[@]}" -eq 3 ] || { echo "board: cannot read the board from the project config" >&2; exit 2; }
OWNER="${V[0]}" NUM="${V[1]}" REPO="${V[2]}"
[[ "$OWNER" =~ ^[A-Za-z0-9-]+$ && "$NUM" =~ ^[0-9]+$ ]] || { echo "board: bad board owner/number" >&2; exit 2; }
OWNER_ONLY_TARGETS='^(Ready for Refinement|Ready for Dev|Ready for Prod)$'
OWNER_ONLY_SOURCES='^(Spec Review|Staged)$'

# Asks only for each card's issue number and Status: a few points per read, where
# `gh project item-list` fetches up to 100 fields per card and costs ~200 points.
# repositoryOwner serves both user and organization boards.
BOARD_QUERY='query { repositoryOwner(login: "'"$OWNER"'") { ... on ProjectV2Owner { projectV2(number: '"$NUM"') { items(first: 100) { nodes {
  id
  content { ... on Issue { number } ... on PullRequest { number } }
  status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
} } } } } }'

fetch_items() {  # one GraphQL read of the board: <issue>\t<status>\t<itemId>
  "$GH" api graphql -f query="$BOARD_QUERY" \
    --jq '.data.repositoryOwner.projectV2.items.nodes[] | select(.content.number != null) | "\(.content.number)\t\(.status.name // "")\t\(.id)"' \
    | strip_owner_mark 2
}

raw_items() {  # reuses FACTORY_BOARD_SNAPSHOT when given (the GraphQL quota is shared with the pipelines)
  if [ -n "${FACTORY_BOARD_SNAPSHOT:-}" ] && [ -s "$FACTORY_BOARD_SNAPSHOT" ]; then cat "$FACTORY_BOARD_SNAPSHOT"; else fetch_items; fi
}
snapshot() { fetch_items; }

# Column names carry an owner mark ("👤 Spec Review", "🤖 Coding"); scripts use the plain name.
strip_owner_mark() {  # strip_owner_mark <tab-separated field number>
  LC_ALL=C awk -F'\t' -v OFS='\t' -v f="$1" '{ sub(/^[^A-Za-z]+ /, "", $f); print }'
}

items()  { raw_items | cut -f1,2; }
status() { raw_items | awk -F'\t' -v n="$1" '$1==n{print $2}'; }
item_id(){ raw_items | awk -F'\t' -v n="$1" '$1==n{print $3}'; }

count() {
  local all; all="$(raw_items)" || return 1
  local total=0 s
  for s in "$@"; do total=$((total + $(printf '%s\n' "$all" | awk -F'\t' -v s="$s" '$2==s' | grep -c .))); done
  echo "$total"
}

eligible() {  # cards in a column without the blocked label, board order; fails closed on lookup errors
  local all n labels out=""; all="$(raw_items)" || return 1
  for n in $(printf '%s\n' "$all" | awk -F'\t' -v s="$1" '$2==s{print $1}'); do
    labels="$("$GH" api "repos/$REPO/issues/$n" --jq '.labels[].name')" || return 1  # REST: separate quota
    printf '%s\n' "$labels" | tr -d '\r' | grep -qx blocked || out="$out$n"$'\n'
  done
  printf '%s' "$out"
}
first() { local list; list="$(eligible "$1")" || return 1; printf '%s\n' "$list" | sed -n '1p' | sed '/^$/d'; }

option_id() {
  "$GH" project field-list "$NUM" --owner "$OWNER" --format json \
    --jq '.fields[] | select(.name=="Status") | .options[] | "\(.name)\t\(.id)"' \
    | strip_owner_mark 1 | awk -F'\t' -v s="$1" '$1==s{print $2}'
}

board_ids() {  # PROJECT_ID and FIELD_ID (Status), looked up once per project and cached
  local cache="${FACTORY_HOME:-$AGHANIM_HOME}/board-ids"
  if [ -s "$cache" ]; then read -r PROJECT_ID FIELD_ID < "$cache"; [ -n "${FIELD_ID:-}" ] && return 0; fi
  PROJECT_ID="$("$GH" project view "$NUM" --owner "$OWNER" --format json --jq .id)" || return 1
  FIELD_ID="$("$GH" project field-list "$NUM" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status") | .id')" || return 1
  [ -n "$PROJECT_ID" ] && [ -n "$FIELD_ID" ] || { echo "board: project $OWNER/$NUM has no Status field" >&2; return 1; }
  mkdir -p "$(dirname "$cache")"; echo "$PROJECT_ID $FIELD_ID" > "$cache"
}

COLUMNS='^(Inbox|Ready for Refinement|Technical Refinement|Spec Review|Ready for Dev|Coding|Validation|Staged|Ready for Prod|Done)$'

move() {
  local n="$1" target="$2" current id opt
  if ! [[ "$target" =~ $COLUMNS ]]; then echo "move: '$target' is not a board column" >&2; return 2; fi
  if [[ "$target" =~ $OWNER_ONLY_TARGETS ]]; then echo "move: only the owner moves cards to '$target'" >&2; return 3; fi
  current="$(status "$n")" || return 1
  if [[ "$current" =~ $OWNER_ONLY_SOURCES ]]; then echo "move: only the owner moves cards out of '$current'" >&2; return 3; fi
  id="$(item_id "$n")"; opt="$(option_id "$target")"
  [ -z "$id" ] && { echo "move: issue #$n is not on the board" >&2; return 1; }
  [ -z "$opt" ] && { echo "move: unknown status '$target'" >&2; return 1; }
  board_ids || return 1
  "$GH" project item-edit --project-id "$PROJECT_ID" --id "$id" --field-id "$FIELD_ID" --single-select-option-id "$opt" >/dev/null
}

cmd="${1:-}"; shift || true
case "$cmd" in
  items|status|count|first|eligible|move|snapshot) "$cmd" "$@" ;;
  *) echo "usage: board.sh items|status <n>|count <status>...|first <status>|move <n> <status>" >&2; exit 2 ;;
esac
