#!/usr/bin/env bash
# suite: unit
# The shipfloor CLI and the project helpers, in process: cli.py (install, add, remove, list, pause, resume, pool, clean,
# accept, setup-board, metrics, usage, doctor), init.py (shipfloor init), project.py (resolve, snapshot, the tmp helpers,
# card specs and weights, sf.py project and sf.py config) and text.py's say. The modules: py/cli_registry.py,
# py/cli_doctor.py, py/cli_init.py, py/cli_project.py (helpers in py/cli_support.py). The wrappers' contract is cli-contract.test.sh's.
source "$(dirname "$0")/lib.sh"
py_suite cli_registry
py_suite cli_doctor
py_suite cli_init
py_suite cli_project
finish
