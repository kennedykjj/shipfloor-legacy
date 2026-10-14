#!/usr/bin/env bash
# Starts factory pipelines for one project's cards waiting in the owner's queues. Run every 3 min by shipfloor-dispatch.sh,
# once per registered project. Pipelines run from the project's control checkout of origin/main, never from a worktree
# an agent can edit. The logic is shipfloor_core/dispatch.py (each run is supervised by its own detached process).
# exit: 0 done, paused or waiting (PAUSE, usage limit, GitHub limit, costs.day_stop) · 1 a board, cost or step failure
#       2 invalid config
set -- dispatch "$@"
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
source "$HERE/lib/py.sh"
