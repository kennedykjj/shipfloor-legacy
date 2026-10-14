#!/usr/bin/env bash
# The machine-wide cycle (shipfloor_core/cycle.py) one project at a time and around them, in process: py/dispatch_cycle.py.
source "$(dirname "$0")/lib.sh"
py_suite dispatch_cycle
finish
