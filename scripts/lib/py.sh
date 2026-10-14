#!/usr/bin/env bash
# Sourced by a wrapper (templates/py-wrapper.sh) that has set HERE to the folder holding sf.py and lib/.
# Finds Python 3 (FACTORY_PYTHON, python3, python), then runs sf.py under `python -I` with the wrapper's arguments.
# Does not source lib/project.sh: one start, no project lookup.
if [ -n "${FACTORY_PYTHON:-}" ]; then SHIPFLOOR_PY="$FACTORY_PYTHON"
elif [ -n "${SHIPFLOOR_PY:-}" ]; then :
elif python3 -c '' >/dev/null 2>&1; then SHIPFLOOR_PY=python3
elif python -c '' >/dev/null 2>&1; then SHIPFLOOR_PY=python
else echo "shipfloor: python 3 not found (set FACTORY_PYTHON)" >&2; exit 127; fi
export SHIPFLOOR_PY
SHIPFLOOR_SF="$HERE/sf.py"
if command -v cygpath >/dev/null 2>&1; then SHIPFLOOR_SF="$(cygpath -m "$SHIPFLOOR_SF")"; fi  # Git Bash: the path Windows Python reads
exec "$SHIPFLOOR_PY" -I "$SHIPFLOOR_SF" "$@"
