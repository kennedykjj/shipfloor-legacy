#!/usr/bin/env bash
# Answers queries about the current project's .shipfloor/factory.yml (commands in shipfloor_config.py).
# step <k>: a factory run records the skill step it is on, for the dashboard. Never fails a run.
if [ "${1:-}" = step ]; then
  if [ -d "${SHIPFLOOR_RUN_LOCK:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then printf '%s	%s
' "$2" "$(date +%s)" > "$SHIPFLOOR_RUN_LOCK/step"; fi
  exit 0
fi
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.  # no dirname: one process less per start
source "$HERE/lib/project.sh"
shipfloor_resolve || exit 2
if [ "${1:-}" = validate ]; then shipfloor_validate; exit $?; fi
shipfloor_cfg "$@"
