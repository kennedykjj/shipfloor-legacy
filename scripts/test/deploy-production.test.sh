#!/usr/bin/env bash
# deploy merging the PR and checking production (CI on main, environment, health, revert), and the card's language
# (in process: scripts/test/py/deploy_production.py).
source "$(dirname "$0")/lib.sh"
py_suite deploy_production
finish
