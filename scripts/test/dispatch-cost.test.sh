#!/usr/bin/env bash
# Cost limits, the dispatcher's side and dashboard_cost.py's estimate, in process: py/dispatch_cost.py.
source "$(dirname "$0")/lib.sh"
py_suite dispatch_cost
finish
