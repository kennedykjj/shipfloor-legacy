#!/usr/bin/env bash
# suite: unit
# Stack slots, leases, the queue, up/down and the heartbeat loop, in process (scripts/test/py/deploy_stack.py).
# Through real processes (the lib/stack.sh shim, signals, the detached heartbeat, a real queue): stack-cli.test.sh.
source "$(dirname "$0")/lib.sh"
py_suite deploy_stack
finish
