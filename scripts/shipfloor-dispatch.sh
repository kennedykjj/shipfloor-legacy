#!/usr/bin/env bash
# One dispatcher cycle for every project in ~/.shipfloor/registry.tsv (slug, repo, worktrees, main).
# For each: bring its control checkout to origin/<main>, validate the config there, then run
# dispatch.sh for it. A project it cannot use is skipped and logged; the others still run.
# The logic is shipfloor_core/cycle.py (#169). SHIPFLOOR_DISPATCH, when set, is run in place of dispatch.sh.
set -- cycle "$@"
export SHIPFLOOR_CYCLE_BASH="$BASH"  # the cycle's own bash: what health and notify are told to use, as before
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
source "$HERE/lib/py.sh"
