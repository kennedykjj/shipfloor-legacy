#!/usr/bin/env bash
# Shared by the factory's sourced code and the tests: finds the project they act on and reads its config.
# Sourced, never run. A shim: the logic is shipfloor_core/project.py, and each function runs `sf.py project <command>`
# with this shell's project (SHIPFLOOR_HOME and FACTORY_*, exported or not). shipfloor_resolve and shipfloor_use export
# FACTORY_PROJECT FACTORY_REPO FACTORY_MAIN FACTORY_HOME FACTORY_WT_ROOT FACTORY_CONFIG here, by an eval of what sf.py
# prints: `export NAME='value' ...`, each value quoted for the shell, or `return 1`.
SHIPFLOOR_LIB="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"  # always sourced by a path ending in lib/project.sh
SHIPFLOOR_HOME="${SHIPFLOOR_HOME:-$HOME/.shipfloor}"
_SHIPFLOOR_SF="$SHIPFLOOR_LIB/../sf.py"
if command -v cygpath >/dev/null 2>&1; then _SHIPFLOOR_SF="$(cygpath -m "$_SHIPFLOOR_SF")"; fi  # the path Windows Python reads

shipfloor_py() {  # SHIPFLOOR_PY = the python 3 binary, found once and handed to the scripts this one starts
  [ -n "${SHIPFLOOR_PY:-}" ] && return 0
  if [ -n "${FACTORY_PYTHON:-}" ]; then SHIPFLOOR_PY="$FACTORY_PYTHON"
  elif python3 -c '' >/dev/null 2>&1; then SHIPFLOOR_PY=python3
  else SHIPFLOOR_PY=python; fi
  export SHIPFLOOR_PY
}
shipfloor_python() { shipfloor_py; "$SHIPFLOOR_PY" -I "$@"; }
_shipfloor_sf() { shipfloor_py; SHIPFLOOR_HOME="$SHIPFLOOR_HOME" FACTORY_CONFIG="${FACTORY_CONFIG:-}" FACTORY_HOME="${FACTORY_HOME:-}" FACTORY_WT_ROOT="${FACTORY_WT_ROOT:-}" FACTORY_REPO="${FACTORY_REPO:-}" "$SHIPFLOOR_PY" -I "$_SHIPFLOOR_SF" project "$@"; }

shipfloor_native() { _shipfloor_sf native "$1"; }                # path as the native Windows tools want it (C:/...), unchanged elsewhere
git_common() { _shipfloor_sf git-common "$1"; }                  # git_common <dir>: its absolute git common dir; nothing outside a repo
shipfloor_use() { eval "$(_shipfloor_sf use "$@")"; }            # shipfloor_use <slug> <repo> [worktrees] [main]: export one registered project's settings
shipfloor_resolve() { [ -n "${FACTORY_CONFIG:-}" ] || eval "$(_shipfloor_sf resolve "$@")"; }  # shipfloor_resolve [dir]: 0 when the project is known, else 1
shipfloor_config_path() { _shipfloor_sf config-path "$1" "$2"; }  # shipfloor_config_path <git-dir> <rev>: the config path committed at rev
shipfloor_snapshot() { _shipfloor_sf snapshot; }                 # FACTORY_CONFIG = the project config as committed at control's HEAD
ere_ok() { _shipfloor_sf ere-ok "$1"; }                          # ere_ok <pattern>: grep -E accepts it
shipfloor_validate() { _shipfloor_sf validate; }                 # the config is valid and every pattern works with grep -E
shipfloor_clean_tmp() { _shipfloor_sf clean-tmp "$1"; }          # shipfloor_clean_tmp <n>: the worktrees a run left under tmp/<n>/, then the directory
shipfloor_stale_tmp() { _shipfloor_sf stale-tmp; }               # card numbers whose tmp/<n>/ outlived them (Done or off the board)
shipfloor_sweep_tmp() { _shipfloor_sf sweep-tmp; }               # removes what outlived its card under tmp/ and prints each as tmp/<name>
shipfloor_card_spec() { _shipfloor_sf card-spec "$@"; }          # shipfloor_card_spec <n> [specs dir]: the card's spec in its worktree
shipfloor_spec_weight() { _shipfloor_sf spec-weight "$1"; }      # shipfloor_spec_weight <spec>: light, standard or heavy
shipfloor_card_weight() { _shipfloor_sf card-weight "$1"; }      # shipfloor_card_weight <n>: the weight of card <n>'s spec
shipfloor_say() { _shipfloor_sf say "${1:-en}"; }                # shipfloor_say <language>: stdin, written in English, in that language (lang/<language>.sed)
shipfloor_machine() { _shipfloor_sf machine "$@"; }              # shipfloor_machine <query...>: the machine-wide settings (~/.shipfloor/config.yml)
shipfloor_cfg() { _shipfloor_sf cfg "$@"; }                      # shipfloor_cfg <query...>: asks shipfloor_config.py about the resolved project
