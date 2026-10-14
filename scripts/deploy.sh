#!/usr/bin/env bash
# Deterministic deploy of one card (docs/superpowers/specs/2026-10-09-fast-safe-deploy-design.md). The logic is shipfloor_core/deploy.py.
# usage: deploy.sh <n> [--refresh | --continue]
#   --refresh   bring a Staged card's PR up to date with main (clean merges only); never merges to main
#   --continue  resume after what a previous run handed over (conflicts, or a red gate or CI) was fixed and committed
# exit: 0 done · 3 handed over to an agent (conflicts in <tmp>/resolve.files, or a fix in <tmp>/fix.findings)
#       4 sent back (to Coding, or to Staged with a fix the owner has to see) · 5 blocked · 6 failed after merge (reverted)
#       2 usage, configuration, transient API error or busy card (safe to retry)
set -- deploy "$@"
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
source "$HERE/lib/py.sh"
