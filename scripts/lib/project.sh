#!/usr/bin/env bash
# Shared by the factory scripts: finds the project they act on and reads its config.
# Sourced, never run. Exports FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT.
AGHANIM_LIB="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"  # always sourced by a path ending in lib/project.sh
AGHANIM_HOME="${AGHANIM_HOME:-$HOME/.aghanim}"

aghanim_native() {  # path as the native Windows tools want it (C:/...), unchanged elsewhere
  if [ -n "$1" ] && command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

aghanim_py() {  # AGHANIM_PY = the python 3 binary, found once and handed to the scripts this one starts
  [ -n "${AGHANIM_PY:-}" ] && return 0
  if [ -n "${FACTORY_PYTHON:-}" ]; then AGHANIM_PY="$FACTORY_PYTHON"
  elif python3 -c '' >/dev/null 2>&1; then AGHANIM_PY=python3
  else AGHANIM_PY=python; fi
  export AGHANIM_PY
}
aghanim_python() { aghanim_py; "$AGHANIM_PY" -I "$@"; }

aghanim_cfg_ready() {  # what every config query needs (python, native paths), found once per project.
  # A query runs in a subshell, where what it finds is lost: aghanim_resolve calls this in the script's own shell.
  local key="$FACTORY_CONFIG|${FACTORY_HOME:-}|${FACTORY_WT_ROOT:-}" p
  [ "$key" = "${AGHANIM_CFG_KEY:-}" ] && return 0
  aghanim_py
  p=("$AGHANIM_LIB/../aghanim_config.py" "$FACTORY_CONFIG" "${FACTORY_HOME:-/}" "${FACTORY_WT_ROOT:-/}")
  # one cygpath start for the four; an unset one goes in as / and comes back empty
  if command -v cygpath >/dev/null; then mapfile -t p < <(cygpath -m "${p[@]}"); fi
  [ -n "${FACTORY_HOME:-}" ] || p[2]=""
  [ -n "${FACTORY_WT_ROOT:-}" ] || p[3]=""
  AGHANIM_CFG=("${p[0]}" --config "${p[1]}" --home "${p[2]}" --worktrees "${p[3]}"); AGHANIM_CFG_KEY="$key"
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
  # A temp file per process: two snapshots at once must not move each other's away. And when the rename
  # fails because a reader has the config open (Windows), a config that did not change is still the config.
  local tmp="$FACTORY_CONFIG.$$.tmp" d p rc=1; d="$(aghanim_native "$FACTORY_HOME/control")"
  p="$(aghanim_config_path "$d" HEAD)" || return 1
  if MSYS2_ARG_CONV_EXCL="*" git -C "$d" show "HEAD:$p" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$FACTORY_CONFIG" 2>/dev/null || cmp -s "$tmp" "$FACTORY_CONFIG"; rc=$?
  fi
  rm -f "$tmp"; return $rc
}

aghanim_resolve() {  # aghanim_resolve [dir]: 0 when the project is known (env, or the registry entry
  # whose repository is the one [dir] belongs to), else 1. The config always comes from the
  # project's control checkout (origin/main), never from the checkout being worked on.
  [ -n "${FACTORY_CONFIG:-}" ] && { aghanim_cfg_ready; return 0; }
  local here slug repo wt main
  here="$(git_common "${1:-.}")"
  if [ -n "$here" ] && [ -f "$AGHANIM_HOME/registry.tsv" ]; then
    while IFS=$'\t' read -r slug repo wt main; do
      [ -z "$slug" ] && continue
      if [ "$(git_common "$repo")" = "$here" ]; then aghanim_use "$slug" "$repo" "$wt" "$main"; aghanim_cfg_ready; return 0; fi
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

aghanim_clean_tmp() {  # aghanim_clean_tmp <n>: the worktrees a run left under the project's tmp/<n>/, then the directory
  local t="$FACTORY_HOME/tmp/$1" w
  [ -d "$t" ] || return 0
  git -C "${FACTORY_REPO:-.}" worktree list --porcelain 2>/dev/null | sed -n 's#^worktree ##p' | grep -F "$(aghanim_native "$t")/" |
    while IFS= read -r w; do git -C "${FACTORY_REPO:-.}" worktree remove --force "$w" 2>/dev/null; done
  git -C "${FACTORY_REPO:-.}" worktree prune 2>/dev/null; rm -rf "$t"
}

aghanim_stale_tmp() {  # aghanim_stale_tmp: card numbers whose tmp/<n>/ outlived them (Done or off the board)
  local d n st
  grep -q '^[0-9]' "$FACTORY_HOME/board.tsv" 2>/dev/null || return 0  # no board read: every card would look gone
  for d in "$FACTORY_HOME"/tmp/*/; do
    n="$(basename "$d")"; [[ "$n" =~ ^[0-9]+$ ]] || continue
    [ -d "$FACTORY_HOME/locks" ] && compgen -G "$FACTORY_HOME/locks/*-$n.lock" >/dev/null && continue
    st="$(awk -F'\t' -v n="$n" '$1==n{print $2}' "$FACTORY_HOME/board.tsv" 2>/dev/null)"
    { [ -z "$st" ] || [ "$st" = Done ]; } && echo "$n"
  done
}

aghanim_sweep_tmp() {  # removes what outlived its card under the project's tmp/ and prints each as tmp/<name>
  local e name n st
  grep -q '^[0-9]' "$FACTORY_HOME/board.tsv" 2>/dev/null || return 0  # no board read: every card would look gone
  for n in $(aghanim_stale_tmp); do aghanim_clean_tmp "$n"; echo "tmp/$n"; done
  # strays beside the card folders (a run that wrote outside its tmp/<n>/): gone once untouched for 3 days,
  # unless the name carries the number of a card still in progress
  for e in "$FACTORY_HOME"/tmp/*; do
    [ -e "$e" ] || continue
    name="$(basename "$e")"
    [ -d "$e" ] && [[ "$name" =~ ^[0-9]+$ ]] && continue
    [ -n "$(find "$e" -mtime -3 -print -quit 2>/dev/null)" ] && continue
    if [[ "$name" =~ ([0-9]+) ]]; then
      st="$(awk -F'\t' -v n="${BASH_REMATCH[1]}" '$1==n{print $2}' "$FACTORY_HOME/board.tsv")"
      [ -n "$st" ] && [ "$st" != Done ] && continue
    fi
    rm -rf "$e" && echo "tmp/$name"
  done
}

aghanim_say() {  # aghanim_say <language>: stdin, written in English, comes out in that language (lang/<language>.sed)
  # The scripts keep saying things in English; the catalog rewrites the phrases it knows and passes the rest.
  local f="$AGHANIM_LIB/../lang/${1:-en}.sed"
  if [ "${1:-en}" != en ] && [ -f "$f" ]; then sed -E -f "$f"; else cat; fi
}

aghanim_machine() {  # aghanim_machine <validate|values|show|set ...>: the machine-wide agent pool (~/.aghanim/config.yml)
  if [ "${AGHANIM_MACHINE_HOME:-}" != "$AGHANIM_HOME" ]; then  # one cygpath start for the two paths, kept while the home is the same
    AGHANIM_MACHINE=("$AGHANIM_HOME/config.yml" "$AGHANIM_LIB/../aghanim_config.py")
    if command -v cygpath >/dev/null; then mapfile -t AGHANIM_MACHINE < <(cygpath -m "${AGHANIM_MACHINE[@]}"); fi
    AGHANIM_MACHINE_HOME="$AGHANIM_HOME"
  fi
  AGHANIM_MACHINE_CONFIG="${AGHANIM_MACHINE[0]}" aghanim_python "${AGHANIM_MACHINE[1]}" machine "$@"
}

aghanim_cfg() {  # aghanim_cfg <query...>: asks aghanim_config.py about the resolved project
  aghanim_cfg_ready; "$AGHANIM_PY" -I "${AGHANIM_CFG[@]}" "$@"
}
