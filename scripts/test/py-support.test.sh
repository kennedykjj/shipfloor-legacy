#!/usr/bin/env bash
# The in-process test runner (scripts/test/py/run.py) and its helpers (support.py) that the module suites use.
source "$(dirname "$0")/lib.sh"
py_suite selftest_support
finish
