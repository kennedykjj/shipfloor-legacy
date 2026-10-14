#!/usr/bin/env bash
# The work area below the belt (#182, AC-1, AC-4, AC-5, AC-6, AC-7): Decide, Run, Card and Calm, drawn by the page's own
# script in node (scripts/test/py/dashboard_work.py, class Area) from overviews shaped like the server's.
source "$(dirname "$0")/lib.sh"
py_suite dashboard_work .Area.
finish
