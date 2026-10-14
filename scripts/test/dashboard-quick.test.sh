#!/usr/bin/env bash
# The owner's decision in the work area (#182, AC-3): the 5 s hold with Undo, the confirmation with doubt, the send when the
# window ends or the page closes, the next card and Calm (scripts/test/py/dashboard_work.py, class Quick).
source "$(dirname "$0")/lib.sh"
py_suite dashboard_work .Quick.
finish
