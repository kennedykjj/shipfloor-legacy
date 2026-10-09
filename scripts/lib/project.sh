#!/usr/bin/env bash
# Shared by the factory scripts: finds the project they act on and reads its config.
# Sourced, never run. Exports FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT.
MYLOS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYLOS_HOME="${MYLOS_HOME:-$HOME/.mylos}"

mylos_native() {  # path as the native Windows tools want it (C:/...), unchanged elsewhere
  if [ -n "$1" ] && command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

mylos_python() {  # python 3 binary, found once
  if [ -z "${MYLOS_PY:-}" ]; then
    if [ -n "${FACTORY_PYTHON:-}" ]; then MYLOS_PY="$FACTORY_PYTHON"
    elif python3 -c '' >/dev/null 2>&1; then MYLOS_PY=python3
    else MYLOS_PY=python; fi
  fi
  "$MYLOS_PY" -I "$@"
}

mylos_resolve() {  # mylos_resolve: 0 when the project is known (env or registry), else 1
  [ -n "${FACTORY_CONFIG:-}" ] && return 0
  echo "mylos: no project here (FACTORY_CONFIG unset)" >&2; return 1
}

mylos_cfg() {  # mylos_cfg <query...>: asks mylos_config.py about the resolved project
  mylos_python "$(mylos_native "$MYLOS_LIB/../mylos_config.py")" --config "$(mylos_native "$FACTORY_CONFIG")" \
    --home "$(mylos_native "${FACTORY_HOME:-}")" --worktrees "$(mylos_native "${FACTORY_WT_ROOT:-}")" "$@"
}
