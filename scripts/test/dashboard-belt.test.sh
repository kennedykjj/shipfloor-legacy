#!/usr/bin/env bash
# The belt (#181), what it shows: each card once as a token in its column's segment with the segment's meta (AC-1), the look of
# each state and the free-slot ghosts (AC-2), the status sentence and the rail that stops when the factory goes silent (AC-5),
# and the keyboard and screen reader contract of the tokens (AC-6). The page's script runs in node on a fake DOM, fed the real
# dashboard server's overview over fake-gh and demo-gh (scripts/test/py/dashboard_belt.py, belt_page.py).
source "$(dirname "$0")/lib.sh"
py_suite dashboard_belt BeltRender
finish
