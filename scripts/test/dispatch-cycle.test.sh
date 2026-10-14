#!/usr/bin/env bash
# suite: unit
# The machine-wide cycle (shipfloor_core/cycle.py) one project at a time and around them, in process: py/dispatch_cycle.py.
# The board history (#184, AC-1, AC-2): the line a cycle records per board change, and the files that stay (py/board_history.py).
source "$(dirname "$0")/lib.sh"
py_suite dispatch_cycle
py_suite board_history
finish
