#!/usr/bin/env bash
# The dashboard's themes, computed from dashboard.html's colors (scripts/test/py/dashboard_theme.py): every theme sets the
# base tokens, keeps its text at 4.5:1 and tells the pool bar's stage hues apart (DESIGN.md names this file).
# The v4 visual system (#180) is pinned beside it (scripts/test/py/dashboard_v4.py): the Floor v4 values, the Settings
# theme groups, the caption and stepper rules, and what DESIGN.md and its sidecar say about them.
source "$(dirname "$0")/lib.sh"
py_suite dashboard_theme
py_suite dashboard_v4
finish
