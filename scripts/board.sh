#!/usr/bin/env bash
# Wrapper: runs `sf.py board <args>` under the factory's Python (the logic is in scripts/shipfloor_core/board.py).
# usage: board.sh items|status <n>|count <status>...|first <status>|move <n> <status>|infra|label <n> add|remove <label>|issue <n>
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
set -- board "$@"
source "$HERE/lib/py.sh"
