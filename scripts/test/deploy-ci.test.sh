#!/usr/bin/env bash
# suite: unit
# deploy pushing the merge of main and waiting for CI, deploy.local_ci and its limit, the fix round's findings
# (in process: scripts/test/py/deploy_ci.py).
source "$(dirname "$0")/lib.sh"
py_suite deploy_ci
finish
