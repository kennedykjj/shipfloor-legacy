#!/usr/bin/env bash
# The dashboard's themes, computed from dashboard.html's colors (scripts/test/py/dashboard_theme.py): every theme sets the
# base tokens, keeps its text at 4.5:1 and tells the pool bar's stage hues apart (DESIGN.md names this file).
source "$(dirname "$0")/lib.sh"
py_suite dashboard_theme
finish
