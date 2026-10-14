#!/usr/bin/env bash
# The dashboard's API in process (scripts/test/py/dashboard_views.py): one dashboard.py server in a thread, a fake gh.
source "$(dirname "$0")/lib.sh"
py_suite dashboard_views
# The belt (#181, AC-1..AC-7): the page's script in node on a fake DOM (BeltRender, BeltMotion) fed this server's overview.
py_suite dashboard_belt
finish
