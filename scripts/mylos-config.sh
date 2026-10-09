#!/usr/bin/env bash
# Answers queries about the current project's .mylos/factory.yml (commands in mylos_config.py).
source "$(dirname "$0")/lib/project.sh"
mylos_resolve || exit 2
if [ "${1:-}" = validate ]; then mylos_validate; exit $?; fi
mylos_cfg "$@"
