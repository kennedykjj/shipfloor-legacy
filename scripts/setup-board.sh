#!/usr/bin/env bash
# One-off: sets the board columns and labels. Rewriting options resets every card's Status,
# so it snapshots item → status first and restores by name, ignoring the 👤/🤖 owner mark
# (pre-factory names: "Ready" → "Ready for Refinement", "Doing" → "Coding").
set -euo pipefail
OWNER=kennedykjj; NUM=2; FIELD=PVTSSF_lAHOAgqatc4BmLV8zhk1YEM; PROJECT=PVT_kwHOAgqatc4BmLV8
snap="${SNAPSHOT:-$(mktemp)}"
gh project item-list "$NUM" --owner "$OWNER" --limit 500 --format json --jq '.items[] | "\(.id)\t\(.status // "")"' > "$snap"
echo "snapshot ($snap): $(wc -l < "$snap") items"
opt() { printf '{name:"%s",color:%s,description:"%s"}' "$1" "$2" "$3"; }
opts="$(opt '👤 Inbox' GRAY 'Ideia capturada'),$(opt '👤 Ready for Refinement' BLUE 'Dono escolheu; fila da esteira 1'),$(opt '🤖 Technical Refinement' PINK 'Spec sendo escrita'),$(opt '👤 Spec Review' PINK 'Spec pronta; aguarda o dono'),$(opt '👤 Ready for Dev' BLUE 'Spec aprovada; fila da esteira 2'),$(opt '🤖 Coding' YELLOW 'Testes de aceite e implementação'),$(opt '🤖 Validation' ORANGE 'Review e verificação'),$(opt '👤 Staged' PURPLE 'PR aberto e CI verde; aguarda o dono'),$(opt '👤 Ready for Prod' BLUE 'Liberado; fila da esteira 3'),$(opt '🤖 Done' GREEN 'Em produção')"
gh api graphql -f query="mutation { updateProjectV2Field(input:{fieldId:\"$FIELD\", singleSelectOptions:[$opts]}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } } }" >/dev/null
ids="$(gh project field-list "$NUM" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status") | .options[] | "\(.name)\t\(.id)"' | LC_ALL=C awk -F'\t' -v OFS='\t' '{ sub(/^[^A-Za-z]+ /, "", $1); print }')"
LC_ALL=C awk -F'\t' -v OFS='\t' '{ sub(/^[^A-Za-z]+ /, "", $2); print }' "$snap" | while IFS=$'\t' read -r item st; do
  [ -z "$st" ] && continue
  [ "$st" = "Ready" ] && st="Ready for Refinement"
  [ "$st" = "Doing" ] && st="Coding"
  o="$(printf '%s\n' "$ids" | awk -F'\t' -v s="$st" '$1==s{print $2}')"
  [ -z "$o" ] && { echo "no option for '$st' (item $item)" >&2; continue; }
  gh project item-edit --project-id "$PROJECT" --id "$item" --field-id "$FIELD" --single-select-option-id "$o" >/dev/null
done
gh label create ui --color 1d76db --description "Issue mexe em tela; o UX/UI entra no refinamento" --force
gh label create cybersec --color b60205 --description "Dono pediu revisão de segurança nas esteiras" --force
gh project item-list "$NUM" --owner "$OWNER" --limit 500 --format json --jq '[.items[] | .status] | group_by(.) | map("\(.[0]): \(length)") | .[]'
