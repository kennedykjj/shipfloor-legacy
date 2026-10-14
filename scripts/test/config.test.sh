#!/usr/bin/env bash
# suite: unit
# shipfloor-config.sh's answers, in process (shipfloor_config.py through shipfloor_core/project.py's config_main):
# py/config_project.py (factory.yml queries, validate's refusals, overrides.yml and the language) and
# py/config_machine.py (config.yml: pool, stages, stacks, notify, costs, hours, dispatcher pace, models).
# The wrapper's own contract through real processes is config-cli.test.sh.
source "$(dirname "$0")/lib.sh"
py_suite config_project
py_suite config_machine
# The runtime contract (scripts/runtimes/): runtime config, claude-code adapter, run log outcome and pause rule: py/runtime.py.
py_suite runtime
finish
