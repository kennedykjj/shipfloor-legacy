#!/usr/bin/env bash
# Deterministic gates for the factory pipelines: gate.sh [-C <worktree>] <gate> ...
# Exit 0 = pass, 1 = blocked (details on stderr), 2 = bad usage or bad revision (never a pass),
# 3 = infrastructure (the run's stack did not come up, or no stack slot in time).
# The gates are Python (shipfloor_core.gate, through sf.py), build, red, green and stack included (gate/run.py);
# `gate.sh -h` prints the usage (shipfloor_core/gate/main.py USAGE):
#   usage: gate.sh test-plan <spec> | weight <spec> | scope <po|ux|techlead|qa|layer> <base> | qa-commit <n> [--head]
#   usage: gate.sh qa-amend <n> | acceptance-intact <qa> | forbidden <base> | migration <base> <spec> | build <base>
#   usage: gate.sh red <layer> <selector> | green <layer> <selector> | stack up <owner> | down <owner> | status
# Callers run this file, and its content is part of the key of a recorded pass (gate/run.py): keep it a wrapper.
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.  # no dirname: one process less per start
# lib/py.sh overwrites SHIPFLOOR_PY with FACTORY_PYTHON; a python a caller handed down (SHIPFLOOR_PY) still answers the
# config queries, as in lib/project.sh: shipfloor_core.gate.main puts it back
export SHIPFLOOR_GATE_PY="${SHIPFLOOR_PY:-}"
set -- gate "$@"
source "$HERE/lib/py.sh"
