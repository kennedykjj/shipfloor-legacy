#!/usr/bin/env bash
# DESIGN.md describes the work area (#182, AC-8): a section The Work Area replaces Your, In Progress, Tooltip Drawer and How a
# Card Opens (scripts/test/py/dashboard_work.py, class Design).
source "$(dirname "$0")/lib.sh"
py_suite dashboard_work .Design.
finish
