#!/usr/bin/env bash
# Deterministic gates for the factory pipelines: gate.sh [-C <worktree>] <gate> ...
# Exit 0 = pass, 1 = blocked (details on stderr), 2 = bad usage or bad revision (never a pass),
# 3 = infrastructure (the run's stack did not come up, or no stack slot in time).
# The gates are Python (shipfloor_core.gate, through sf.py), build, red, green and stack included (gate/run.py).
# Callers run this file, and its content is part of the key of a recorded pass (gate/run.py): keep it a wrapper.
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.; HERE="$(cd "$HERE" && pwd)"  # no dirname: one process less per start

usage() {  # the same text as shipfloor_core/gate/main.py USAGE
  cat <<'EOF'
usage: gate.sh [-C <worktree>] <gate> ...
  test-plan <spec>                         every AC of the spec has a test its layer's runner can run
  weight <spec>                            the spec's header names one weight: light, standard or heavy
  scope <po|ux|techlead|qa|layer> <base>   only that role's files changed since <base>
  qa-commit <n> [--head]                   prints card <n>'s QA commit; --head: it must be the last commit
  qa-amend <n>                             QA's amendment of its own acceptance tests is honest
  acceptance-intact <qa>                   the acceptance tests are as QA committed them
  forbidden <base>                         no forbidden file changed since <base>
  migration <base> <spec>                  applied migrations untouched, destructive ones have a rollback
  build <base>                             each layer changed since <base> builds (reuses a pass recorded on this commit)
  red <layer> <selector>                   the tests fail on an assertion (before the implementation)
  green <layer> <selector>                 the tests ran and pass (reuses a pass recorded on this commit)
  stack up <owner> | down <owner> | status
<base> and <qa> are commits. Exit: 0 pass, 1 blocked, 2 bad usage or revision, 3 infrastructure.
A gate's last line on stderr is its verdict: "gate <name>: pass", "FAIL (exit 1)" or "INFRA (exit 3)".
In a factory run (SHIPFLOOR_RUN_LOCK), the verdict is also written to <lock>/last-gate for the dispatcher.
EOF
}
case "${1:-}" in -h|--help|help) usage; exit 0 ;; "") usage >&2; exit 2 ;; esac

# lib/py.sh overwrites SHIPFLOOR_PY with FACTORY_PYTHON; a python a caller handed down (SHIPFLOOR_PY) still answers the
# config queries, as in lib/project.sh: shipfloor_core.gate.main puts it back
export SHIPFLOOR_GATE_PY="${SHIPFLOOR_PY:-}"
set -- gate "$@"
source "$HERE/lib/py.sh"
