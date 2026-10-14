#!/usr/bin/env bash
# suite: unit
# The dashboard's API in process (scripts/test/py/dashboard_views.py, scripts/test/py/dashboard_settings.py): one
# dashboard.py server in a thread, a fake gh.
source "$(dirname "$0")/lib.sh"
py_suite dashboard_views
py_suite dashboard_settings
# The belt (#181, AC-1..AC-7): the page's script in node on a fake DOM (BeltRender, BeltMotion) fed this server's overview.
py_suite dashboard_belt
# The day in replay (#184): GET /api/day/<project> (AC-3 server side), and the page's scrubber, replay and Logbook (AC-3..AC-8).
py_suite dashboard_day
py_suite dashboard_replay
finish
