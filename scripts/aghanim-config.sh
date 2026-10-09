#!/usr/bin/env bash
# Answers queries about the current project's .aghanim/factory.yml (commands in aghanim_config.py).
source "$(dirname "$0")/lib/project.sh"
aghanim_resolve || exit 2
if [ "${1:-}" = validate ]; then aghanim_validate; exit $?; fi
aghanim_cfg "$@"
