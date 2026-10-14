#!/usr/bin/env bash
# suite: unit
# What a launched run gets and does (argv, environment, log lines, models and step-up, deploy rounds, TMPDIR, cleanup), in process: py/dispatch_launch.py.
source "$(dirname "$0")/lib.sh"
py_suite dispatch_launch
finish
