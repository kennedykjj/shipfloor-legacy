#!/usr/bin/env bash
# Shared by the factory scripts: finds the project they act on and reads its config.
# Sourced, never run. Exports FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT.
AGHANIM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGHANIM_HOME="${AGHANIM_HOME:-$HOME/.aghanim}"

aghanim_native() {  # path as the native Windows tools want it (C:/...), unchanged elsewhere
  if [ -n "$1" ] && command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

aghanim_python() {  # python 3 binary, found once
  if [ -z "${AGHANIM_PY:-}" ]; then
    if [ -n "${FACTORY_PYTHON:-}" ]; then AGHANIM_PY="$FACTORY_PYTHON"
    elif python3 -c '' >/dev/null 2>&1; then AGHANIM_PY=python3
    else AGHANIM_PY=python; fi
  fi
  "$AGHANIM_PY" -I "$@"
}

git_common() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }

aghanim_use() {  # aghanim_use <slug> <repo> [worktrees] [main]: export one registered project's settings
  export FACTORY_PROJECT="$1" FACTORY_REPO="$2" FACTORY_MAIN="${4:-main}"
  export FACTORY_HOME="$AGHANIM_HOME/projects/$1"
  export FACTORY_WT_ROOT="${3:-$FACTORY_HOME/wt}"
  # The gates obey a snapshot of the committed config, kept outside the control checkout where
  # pipelines run (and could edit files): see aghanim_snapshot.
  export FACTORY_CONFIG="$FACTORY_HOME/factory.yml"
}

aghanim_config_path() {  # aghanim_config_path <git-dir> <rev>: the config path committed at rev
  local d="$1" rev="$2" p
  for p in .aghanim/factory.yml .mylos/factory.yml; do  # legacy mylos: drop .mylos once no project uses it
    # Git Bash would take "<rev>:.aghanim/..." for a path list and mangle it
    if MSYS2_ARG_CONV_EXCL="*" git -C "$d" cat-file -e "$rev:$p" 2>/dev/null; then
      [ "$p" = .aghanim/factory.yml ] || echo "aghanim: $d: using legacy .mylos/factory.yml; move it to .aghanim/" >&2  # legacy mylos
      echo "$p"; return 0
    fi
  done
  return 1
}

aghanim_snapshot() {  # aghanim_snapshot: FACTORY_CONFIG = the project config as committed at control's HEAD
  local tmp="$FACTORY_CONFIG.tmp" d p; d="$(aghanim_native "$FACTORY_HOME/control")"
  p="$(aghanim_config_path "$d" HEAD)" || return 1
  MSYS2_ARG_CONV_EXCL="*" git -C "$d" show "HEAD:$p" > "$tmp" 2>/dev/null     && mv "$tmp" "$FACTORY_CONFIG" || { rm -f "$tmp"; return 1; }
}

aghanim_resolve() {  # aghanim_resolve [dir]: 0 when the project is known (env, or the registry entry
  # whose repository is the one [dir] belongs to), else 1. The config always comes from the
  # project's control checkout (origin/main), never from the checkout being worked on.
  [ -n "${FACTORY_CONFIG:-}" ] && return 0
  local here slug repo wt main
  here="$(git_common "${1:-.}")"
  if [ -n "$here" ] && [ -f "$AGHANIM_HOME/registry.tsv" ]; then
    while IFS=$'\t' read -r slug repo wt main; do
      [ -z "$slug" ] && continue
      if [ "$(git_common "$repo")" = "$here" ]; then aghanim_use "$slug" "$repo" "$wt" "$main"; return 0; fi
    done < "$AGHANIM_HOME/registry.tsv"
  fi
  echo "aghanim: $(pwd) is not in a registered project (aghanim add <repo>)" >&2; return 1
}

ere_ok() {  # ere_ok <pattern>: grep -E accepts it (status 2 = invalid pattern)
  printf '' | grep -E -- "$1" >/dev/null 2>&1; [ $? -ne 2 ]
}

aghanim_validate() {  # aghanim_validate: the config is valid and every pattern works with grep -E
  aghanim_cfg validate || return 1
  local p bad=0
  while IFS= read -r -d '' p; do
    ere_ok "$p" || { echo "aghanim-config: $FACTORY_CONFIG: '$p' is not a valid grep -E pattern" >&2; bad=1; }
  done < <(aghanim_cfg patterns)
  return $bad
}

aghanim_machine() {  # aghanim_machine <validate|values|show|set ...>: the machine-wide agent pool (~/.aghanim/config.yml)
  AGHANIM_MACHINE_CONFIG="$(aghanim_native "$AGHANIM_HOME/config.yml")"     aghanim_python "$(aghanim_native "$AGHANIM_LIB/../aghanim_config.py")" machine "$@"
}

aghanim_cfg() {  # aghanim_cfg <query...>: asks aghanim_config.py about the resolved project
  aghanim_python "$(aghanim_native "$AGHANIM_LIB/../aghanim_config.py")" --config "$(aghanim_native "$FACTORY_CONFIG")" \
    --home "$(aghanim_native "${FACTORY_HOME:-}")" --worktrees "$(aghanim_native "${FACTORY_WT_ROOT:-}")" "$@"
}
