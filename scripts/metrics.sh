#!/usr/bin/env bash
# Prints one TSV line per report: issue pipeline outcome tokens duration_min rounds gates_failed manual_edit
set -euo pipefail
source "$(dirname "$0")/lib/project.sh"
mylos_resolve . || exit 2
HOME_DIR="$FACTORY_HOME"
WT="$HOME_DIR/reports-wt"
git -C "$WT" pull -q --rebase origin factory-reports 2>/dev/null || true
REPORTS="$WT/reports"
command -v cygpath >/dev/null && REPORTS="$(cygpath -w "$REPORTS")"
python -I - "$REPORTS" <<'PY'
import json, sys, pathlib
from datetime import datetime
print("issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit")
for p in sorted(pathlib.Path(sys.argv[1]).glob("*/*.json")):
    r = json.loads(p.read_text(encoding="utf-8"))
    tokens = sum((a.get("tokens") or 0) for a in r.get("agents", []))
    try:
        mins = round((datetime.fromisoformat(r["finished_at"]) - datetime.fromisoformat(r["started_at"])).total_seconds() / 60)
    except (KeyError, ValueError):
        mins = ""
    rounds = sum(r.get("rounds", {}).values())
    manual = "" if r.get("manual_edit") is None else r["manual_edit"]
    print(f'{r["issue"]}\t{r["pipeline"]}\t{r["outcome"]}\t{tokens}\t{mins}\t{rounds}\t{",".join(r.get("gates_failed", []))}\t{manual}')
PY
