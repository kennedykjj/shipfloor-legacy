#!/usr/bin/env bash
# deploy fix rounds: red CI or a red gate after merging main, and what --continue accepts as a fix
# (in process: scripts/test/py/deploy_fix.py).
source "$(dirname "$0")/lib.sh"
py_suite deploy_fix
finish
