#!/usr/bin/env bash
# suite: unit
# The gates around QA's acceptance tests (acceptance-intact, acceptance-own, qa-commit, qa-amend), in process on temp
# repos (scripts/test/py/gate_accept.py).
# uses gate.sh sf.py main.py context.py acceptance.py changes.py scope.py text.py proc.py gate_accept.py
#      gate_support.py support.py
source "$(dirname "$0")/lib.sh"
py_suite gate_accept
finish
