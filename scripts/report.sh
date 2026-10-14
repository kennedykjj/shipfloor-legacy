#!/usr/bin/env bash
# Commits a factory report to the orphan branch factory-reports (never merged, never deployed). The logic is shipfloor_core/report.py.
# report.json schema: {"issue","slug","pipeline","started_at","finished_at","outcome":"ok|blocked|infra",
#   "agents":[{"role","tokens","duration_s"}],"rounds":{step:n},"gates_failed":[...],"flaky":["<layer> <selector>"],"gates_reused":["build","green <layer> <selector>"],"manual_edit":true|false|null}
set -- report "$@"
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
source "$HERE/lib/py.sh"
