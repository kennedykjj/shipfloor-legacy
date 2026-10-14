#!/usr/bin/env bash
# deploy, in process (shipfloor_core/deploy.py):
#   deploy_start       the start of a run and the approval (scripts/test/py/deploy_start.py)
#   deploy_merge       merging main into the PR: conflicts, limits, migrations, --continue (deploy_merge.py)
#   deploy_ci          pushing the merge of main and waiting for CI, deploy.local_ci and its limit, the fix round's findings (deploy_ci.py)
#   deploy_fix         fix rounds: red CI or a red gate after merging main, and what --continue accepts as a fix (deploy_fix.py)
#   deploy_production  merging the PR and checking production (CI on main, environment, health, revert), and the card's language
#                      (deploy_production.py)
source "$(dirname "$0")/lib.sh"
py_suite deploy_start
py_suite deploy_merge
py_suite deploy_ci
py_suite deploy_fix
py_suite deploy_production
finish
