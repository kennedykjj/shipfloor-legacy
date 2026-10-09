#!/usr/bin/env bash
# One-off per project: sets the board's Status columns and the factory labels. Rewriting the
# options resets every card's Status, so it snapshots item → status first and restores by name,
# ignoring the 👤/🤖 owner mark. Cards whose status has no column keep an empty Status (listed).
set -euo pipefail
source "$(dirname "$0")/lib/project.sh"
aghanim_resolve . || exit 2
mapfile -d '' -t V < <(aghanim_cfg values board.owner board.number project.repo)
OWNER="${V[0]}" NUM="${V[1]}" REPO="${V[2]}"
PROJECT="$(gh project view "$NUM" --owner "$OWNER" --format json --jq .id)"
FIELD="$(gh project field-list "$NUM" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status") | .id')"
[ -n "$FIELD" ] || { echo "setup-board: project $OWNER/$NUM has no Status field" >&2; exit 1; }
snap="${SNAPSHOT:-$(mktemp)}"
gh project item-list "$NUM" --owner "$OWNER" --limit 500 --format json --jq '.items[] | "\(.id)\t\(.status // "")"' > "$snap"
echo "snapshot ($snap): $(wc -l < "$snap") items"
opt() { printf '{name:"%s",color:%s,description:"%s"}' "$1" "$2" "$3"; }
opts="$(opt '👤 Inbox' GRAY 'Idea captured'),$(opt '👤 Ready for Refinement' BLUE 'Owner picked it; refine queue'),$(opt '🤖 Technical Refinement' PINK 'Spec being written'),$(opt '👤 Spec Review' PINK 'Spec ready; waits for the owner'),$(opt '👤 Ready for Dev' BLUE 'Spec approved; develop queue'),$(opt '🤖 Coding' YELLOW 'Acceptance tests and implementation'),$(opt '🤖 Validation' ORANGE 'Validate queue: review, PR and CI'),$(opt '👤 Staged' PURPLE 'PR open and CI green; waits for the owner'),$(opt '👤 Ready for Prod' BLUE 'Released; deploy queue'),$(opt '🤖 Done' GREEN 'In production')"
gh api graphql -f query="mutation { updateProjectV2Field(input:{fieldId:\"$FIELD\", singleSelectOptions:[$opts]}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } } }" >/dev/null
ids="$(gh project field-list "$NUM" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status") | .options[] | "\(.name)\t\(.id)"' | LC_ALL=C awk -F'\t' -v OFS='\t' '{ sub(/^[^A-Za-z]+ /, "", $1); print }')"
LC_ALL=C awk -F'\t' -v OFS='\t' '{ sub(/^[^A-Za-z]+ /, "", $2); print }' "$snap" | while IFS=$'\t' read -r item st; do
  [ -z "$st" ] && continue
  o="$(printf '%s\n' "$ids" | awk -F'\t' -v s="$st" '$1==s{print $2}')"
  [ -z "$o" ] && { echo "no column for '$st' (item $item): left without Status" >&2; continue; }
  gh project item-edit --project-id "$PROJECT" --id "$item" --field-id "$FIELD" --single-select-option-id "$o" >/dev/null
done
gh label create ui --repo "$REPO" --color 1d76db --description "Issue touches UI; UX/UI joins the refinement" --force
gh label create cybersec --repo "$REPO" --color b60205 --description "Owner asked for a security review in the pipelines" --force
gh label create blocked --repo "$REPO" --color 000000 --description "The factory stopped on this card; the owner decides" --force
rm -f "${FACTORY_HOME:-$AGHANIM_HOME}/board-ids"
gh project item-list "$NUM" --owner "$OWNER" --limit 500 --format json --jq '[.items[] | .status] | group_by(.) | map("\(.[0]): \(length)") | .[]'
