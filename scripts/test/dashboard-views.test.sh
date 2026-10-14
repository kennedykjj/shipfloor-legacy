#!/usr/bin/env bash
# suite: unit
# The dashboard's API in process (scripts/test/py/dashboard_views.py, scripts/test/py/dashboard_settings.py): one
# dashboard.py server in a thread, a fake gh.
source "$(dirname "$0")/lib.sh"
py_suite dashboard_views
py_suite dashboard_settings
finish
