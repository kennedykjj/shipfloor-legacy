#!/usr/bin/env bash
# Answers queries about the current project's .shipfloor/factory.yml. The logic is `sf.py config`
# (shipfloor_core/project.py, the queries in shipfloor_config.py).
# step <k>: a factory run records the skill step it is on, for the dashboard. Never fails a run, never starts Python.
if [ "${1:-}" = step ]; then
  if [ -d "${SHIPFLOOR_RUN_LOCK:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then printf '%s\t%s\n' "$2" "$(date +%s)" > "$SHIPFLOOR_RUN_LOCK/step"; fi
  exit 0
fi
# machine ...: the machine's own file, needs no project (the installer asks from anywhere); anything else needs one (exit 2)
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.  # no dirname: one process less per start
set -- config "$@"
source "$HERE/lib/py.sh"
