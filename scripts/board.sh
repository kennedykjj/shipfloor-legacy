#!/usr/bin/env bash
# Reads and moves cards on the project's board (a GitHub Project v2, from .shipfloor/factory.yml).
set -uo pipefail
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.  # no dirname: one process less per start
source "$HERE/lib/project.sh"
GH="${FACTORY_GH:-gh}"
shipfloor_resolve . || exit 2
mapfile -d '' -t V < <(shipfloor_cfg values board.owner board.number project.repo 2>/dev/null)
[ "${#V[@]}" -eq 3 ] || { echo "board: cannot read the board from the project config" >&2; exit 2; }
OWNER="${V[0]}" NUM="${V[1]}" REPO="${V[2]}"
[[ "$OWNER" =~ ^[A-Za-z0-9-]+$ && "$NUM" =~ ^[0-9]+$ ]] || { echo "board: bad board owner/number" >&2; exit 2; }
OWNER_ONLY_TARGETS='^(Ready for Refinement|Ready for Dev|Ready for Prod)$'
OWNER_ONLY_SOURCES='^(Spec Review|Staged)$'

# Asks only for each card's issue number and Status: a few points per read, where
# `gh project item-list` fetches up to 100 fields per card and costs ~200 points.
# repositoryOwner serves both user and organization boards. The items come in the project's own order, the one the owner
# sets by dragging (#128): a column's cards in that order are its queue, and eligible and first keep it.
BOARD_QUERY='query { repositoryOwner(login: "'"$OWNER"'") { ... on ProjectV2Owner { projectV2(number: '"$NUM"') { items(first: 100, orderBy: {field: POSITION, direction: ASC}) { nodes {
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
    # no pipe into grep -q: it leaves at the first match, the writer dies of SIGPIPE, and pipefail then reads "no match"
    grep -qxE 'blocked|blocked:infra' <<< "${labels//$'\r'/}" || out="$out$n"$'\n'
  done
  printf '%s' "$out"
}
infra() { "$GH" api "repos/$REPO/issues?labels=blocked:infra&state=open&per_page=100" --jq '.[].number'; }
label() {  # label <n> add|remove <name>: an absent label is not an error when removing
  case "${2:-}" in
    add) "$GH" api -X POST "repos/$REPO/issues/$1/labels" -f "labels[]=$3" >/dev/null ;;
    remove) "$GH" api -X DELETE "repos/$REPO/issues/$1/labels/$3" >/dev/null 2>&1 || true ;;
    *) echo "label: <n> add|remove <name>" >&2; return 2 ;;
  esac
}
first() { local list; list="$(eligible "$1")" || return 1; printf '%s\n' "$list" | sed -n '1p' | sed '/^$/d'; }

option_id() {
  "$GH" project field-list "$NUM" --owner "$OWNER" --format json \
    --jq '.fields[] | select(.name=="Status") | .options[] | "\(.name)\t\(.id)"' \
    | strip_owner_mark 1 | awk -F'\t' -v s="$1" '$1==s{print $2}'
}

board_ids() {  # PROJECT_ID and FIELD_ID (Status), looked up once per project and cached
  local cache="${FACTORY_HOME:-$SHIPFLOOR_HOME}/board-ids"
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

issue() {  # issue <n>: the issue as an agent may read it: title, body and the comments of the people it listens to.
  # Anyone can comment on a public repository, and to an agent a comment is an instruction. It listens to this factory's
  # GitHub user and to the project's trusted_commenters ("*" is anyone); the other comments are left out.
  local n="${1:-}" me who
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "issue: <n> must be a number" >&2; return 2; }
  me="$("$GH" api user --jq .login)" && [ -n "$me" ] || { echo "issue: cannot read the GitHub user" >&2; return 1; }
  who="$(shipfloor_cfg get trusted_commenters 2>/dev/null)"
  "$GH" issue view "$n" --repo "$REPO" --json number,title,body,comments | ME="$me" WHO="$who" shipfloor_python -c '
import json, os, sys
d, me = json.load(sys.stdin), os.environ["ME"]
who = set(os.environ["WHO"].split()) | {me}
mine = [c for c in d.get("comments") or [] if "*" in who or (c.get("author") or {}).get("login") in who]
print("#%s %s\n\n%s" % (d["number"], d["title"], d.get("body") or ""))
for c in mine:
    print("\n--- comment by %s, %s\n%s" % ((c.get("author") or {}).get("login", "?"), c.get("createdAt", ""), c.get("body") or ""))
left = len(d.get("comments") or []) - len(mine)
if left:
    print("\n(%d comment%s by other people not shown)" % (left, "" if left == 1 else "s"))'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  items|status|count|first|eligible|move|snapshot|infra|label|issue) "$cmd" "$@" ;;
  *) echo "usage: board.sh items|status <n>|count <status>...|first <status>|move <n> <status>|infra|label <n> add|remove <label>|issue <n>" >&2; exit 2 ;;
esac
