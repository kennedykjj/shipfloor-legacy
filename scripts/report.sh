#!/usr/bin/env bash
# Commits a factory report to the orphan branch factory-reports (never merged, never deployed).
# report.json schema: {"issue","slug","pipeline","started_at","finished_at","outcome":"ok|blocked|infra",
#   "agents":[{"role","tokens","duration_s"}],"rounds":{step:n},"gates_failed":[...],"flaky":["<layer> <selector>"],"manual_edit":true|false|null}
set -euo pipefail
source "$(dirname "$0")/lib/project.sh"
shipfloor_resolve . || exit 2
[ $# -eq 5 ] || { echo "usage: report.sh <issue> <slug> <pipeline> <report.json> <report.md>" >&2; exit 2; }
issue="$1" slug="$2" pipeline="$3" json="$4" md="$5"
HOME_DIR="$FACTORY_HOME"
REPO="${FACTORY_REPO:-$(git rev-parse --show-toplevel)}"
WT="$HOME_DIR/reports-wt"
BR=factory-reports

if [ ! -e "$WT/.git" ]; then
  git -C "$REPO" fetch -q origin "$BR" 2>/dev/null || true
  if git -C "$REPO" rev-parse -q --verify "origin/$BR" >/dev/null; then
    git -C "$REPO" worktree add -q -B "$BR" "$WT" "origin/$BR"
  else
    git -C "$REPO" worktree add -q --detach "$WT"
    git -C "$WT" checkout -q --orphan "$BR"
    git -C "$WT" rm -rqf . >/dev/null 2>&1 || true
    echo "# Factory reports" > "$WT/README.md"
    git -C "$WT" add README.md
    git -C "$WT" commit -qm "chore(factory): start reports branch"
  fi
fi
git -C "$WT" pull -q --rebase origin "$BR" 2>/dev/null || true
stamp="$(date +%Y-%m-%dT%H%M%S)"
dir="$WT/reports/$issue-$slug"; mkdir -p "$dir"
cp "$json" "$dir/$pipeline-$stamp.json"; cp "$md" "$dir/$pipeline-$stamp.md"
git -C "$WT" add reports
git -C "$WT" commit -qm "chore(factory): report #$issue $pipeline $stamp" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C "$WT" push -q origin "$BR"
