#!/usr/bin/env bash
# The runtime contract (scripts/runtimes/): the runtime config (none, string, map, project over machine, invalid), the claude-code adapter, the run log's outcome and the pause rule, in process: py/runtime.py.
source "$(dirname "$0")/lib.sh"
py_suite runtime
finish
