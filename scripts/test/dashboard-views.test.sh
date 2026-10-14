#!/usr/bin/env bash
# The dashboard's API in process (scripts/test/py/dashboard_views.py): one dashboard.py server in a thread, a fake gh.
source "$(dirname "$0")/lib.sh"
py_suite dashboard_views
finish
