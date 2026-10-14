#!/usr/bin/env bash
# The gates that run a layer's commands, in process with runner doubles (scripts/test/py):
#   gate_run    build, red, green, install, retry, red/green on a needs_stack layer
#   gate_cache  the pass cache of build and green: key, record, reuse, pruning, the code in the key
# uses gate.sh sf.py main.py context.py run.py changes.py stack.py text.py gate_run.py gate_cache.py gate_support.py
#      support.py
source "$(dirname "$0")/lib.sh"
py_suite gate_run
py_suite gate_cache
finish
