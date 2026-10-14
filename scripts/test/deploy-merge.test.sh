#!/usr/bin/env bash
# deploy merging main into the PR: conflicts, limits, migrations, --continue (in process: scripts/test/py/deploy_merge.py).
source "$(dirname "$0")/lib.sh"
py_suite deploy_merge
finish
