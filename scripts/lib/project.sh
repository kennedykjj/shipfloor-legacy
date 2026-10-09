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

git_common() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }

mylos_use() {  # mylos_use <slug> <repo> [worktrees] [main]: export one registered project's settings
  export FACTORY_PROJECT="$1" FACTORY_REPO="$2" FACTORY_MAIN="${4:-main}"
  export FACTORY_HOME="$MYLOS_HOME/projects/$1"
  export FACTORY_WT_ROOT="${3:-$FACTORY_HOME/wt}"
  export FACTORY_CONFIG="$FACTORY_HOME/control/.mylos/factory.yml"
}

mylos_resolve() {  # mylos_resolve [dir]: 0 when the project is known (env, or the registry entry
  # whose repository is the one [dir] belongs to), else 1. The config always comes from the
  # project's control checkout (origin/main), never from the checkout being worked on.
  [ -n "${FACTORY_CONFIG:-}" ] && return 0
  local here slug repo wt main
  here="$(git_common "${1:-.}")"
  if [ -n "$here" ] && [ -f "$MYLOS_HOME/registry.tsv" ]; then
    while IFS=$'\t' read -r slug repo wt main; do
      [ -z "$slug" ] && continue
      if [ "$(git_common "$repo")" = "$here" ]; then mylos_use "$slug" "$repo" "$wt" "$main"; return 0; fi
    done < "$MYLOS_HOME/registry.tsv"
  fi
  echo "mylos: $(pwd) is not in a registered project (mylos add <repo>)" >&2; return 1
}

mylos_cfg() {  # mylos_cfg <query...>: asks mylos_config.py about the resolved project
  mylos_python "$(mylos_native "$MYLOS_LIB/../mylos_config.py")" --config "$(mylos_native "$FACTORY_CONFIG")" \
    --home "$(mylos_native "${FACTORY_HOME:-}")" --worktrees "$(mylos_native "${FACTORY_WT_ROOT:-}")" "$@"
}
