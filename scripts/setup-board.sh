#!/usr/bin/env bash
# Wrapper: runs `sf.py setup-board <args>` under the factory's Python.
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
set -- setup-board "$@"
source "$HERE/lib/py.sh"
