#!/usr/bin/env bash
# suite: unit
# #173 (RES-01) AC-6: a write that fails as if the disk were full, during an install or a report. In process, with a
# double that stops a write half way with ENOSPC (py/chaos_fs.py); the files and the dashboard's readers are checked
# after the failure and after the next try.
source "$(dirname "$0")/lib.sh"
py_suite chaos_fs
finish
