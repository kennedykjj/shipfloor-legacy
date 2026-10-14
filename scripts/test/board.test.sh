#!/usr/bin/env bash
# suite: unit
# The board, in process (shipfloor_core/board.py and setup.py against a fake gh, py/board_support.py): reads, GraphQL
# and REST paths, eligible/first, FACTORY_BOARD_SNAPSHOT (py/board_read.py); move, label, issue, config errors and
# setup-board (py/board_write.py). The board.sh / setup-board.sh contract is board-cli.test.sh.
source "$(dirname "$0")/lib.sh"
py_suite board_read
py_suite board_write
finish
