"""metrics: one TSV line per factory report: issue pipeline outcome tokens duration_min rounds gates_failed manual_edit."""
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime

from . import project

HEADER = "issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit"


def main(argv):
    try:
        project.resolve(".")
    except project.ProjectError as e:
        print(e, file=sys.stderr)
        return 2
    home = os.environ.get("FACTORY_HOME")
    if home is None:  # what `set -u` said in the Bash script
        print("metrics.sh: FACTORY_HOME: unbound variable", file=sys.stderr)
        return 1
    wt = os.path.join(home, "reports-wt")
    try:
        subprocess.run(["git", "-C", wt, "pull", "-q", "--rebase", "origin", "factory-reports"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass
    print(HEADER)
    # A report without issue, pipeline or outcome raises KeyError on purpose: the rows before it stay printed.
    for p in sorted(pathlib.Path(wt, "reports").glob("*/*.json")):
        r = json.loads(p.read_text(encoding="utf-8"))
        tokens = sum((a.get("tokens") or 0) for a in r.get("agents", []))
        try:
            mins = round((datetime.fromisoformat(r["finished_at"]) - datetime.fromisoformat(r["started_at"])).total_seconds() / 60)
        except (KeyError, ValueError):
            mins = ""
        rounds = sum(r.get("rounds", {}).values())
        manual = "" if r.get("manual_edit") is None else r["manual_edit"]
        print(f'{r["issue"]}\t{r["pipeline"]}\t{r["outcome"]}\t{tokens}\t{mins}\t{rounds}\t{",".join(r.get("gates_failed", []))}\t{manual}')
    return 0
