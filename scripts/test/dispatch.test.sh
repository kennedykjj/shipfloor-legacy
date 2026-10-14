#!/usr/bin/env bash
# suite: unit
# What a dispatcher cycle starts and what it leaves (queues, WIP, pool, locks, waits, blocked-by dependencies, infra retry, exits, the board read, tmp sweep, control checkout), in process: py/dispatch_select.py.
source "$(dirname "$0")/lib.sh"
py_suite dispatch_select
finish
