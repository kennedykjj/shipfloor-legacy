#!/usr/bin/env bash
# Prints one TSV line per report: issue pipeline outcome tokens duration_min rounds gates_failed manual_edit. The logic is shipfloor_core/metrics.py.
set -- metrics "$@"
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
source "$HERE/lib/py.sh"
