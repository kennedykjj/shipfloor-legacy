#!/usr/bin/env bash
# suite: unit
# The gates that read the spec and the changed set, and gate.sh's dispatch, in process (scripts/test/py):
#   gate_main  usage, -C, the project, the verdict and last-gate, the language, stdout as data, the config's checks
#   gate_spec  weight and test-plan
#   gate_diff  scope, forbidden, migration and fast on temp repos; text.ere_match
# uses gate.sh sf.py main.py context.py spec.py changes.py scope.py migration.py acceptance.py text.py project.py
#      shipfloor_config.py gate_main.py gate_spec.py gate_diff.py gate_support.py support.py
source "$(dirname "$0")/lib.sh"
py_suite gate_main
py_suite gate_spec
py_suite gate_diff
finish
