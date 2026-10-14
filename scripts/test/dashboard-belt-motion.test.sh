#!/usr/bin/env bash
# The belt (#181), what moves: a card that changes column travels and the gate it reaches rings once (AC-3), nothing animates
# under prefers-reduced-motion (AC-4), and under 1020px the belt scrolls inside its own container (AC-7). The page's script runs
# in node on a fake DOM with the page's CSS evaluated for the viewport and the motion preference (scripts/test/py/belt_page.py).
source "$(dirname "$0")/lib.sh"
py_suite dashboard_belt BeltMotion
finish
