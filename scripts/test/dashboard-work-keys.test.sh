#!/usr/bin/env bash
# The work area's keys (#182, AC-2): A approves, R opens Request changes, N skips, Enter sends the note, Esc steps back; none of
# them acts in a text field, a select or outside Decide (scripts/test/py/dashboard_work.py, class Keys).
source "$(dirname "$0")/lib.sh"
py_suite dashboard_work .Keys.
finish
