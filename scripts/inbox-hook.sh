#!/usr/bin/env bash
# PostToolUse hook of a factory run: hands the owner's messages (the dashboard's Live tab) to the agents
# between two tool calls. Nothing to hand over is the usual case, and it must cost nothing.
[ -s "${SHIPFLOOR_RUN_LOCK:-}/inbox" ] || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
shipfloor_python "$(shipfloor_native "$SHIPFLOOR_LIB/../inbox_hook.py")"
