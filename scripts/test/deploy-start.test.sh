#!/usr/bin/env bash
# suite: unit
# deploy, the start of a run and the approval (shipfloor_core/deploy.py in process: scripts/test/py/deploy_start.py).
source "$(dirname "$0")/lib.sh"
py_suite deploy_start
finish
