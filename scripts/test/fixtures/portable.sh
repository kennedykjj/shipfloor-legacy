#!/usr/bin/env bash
# Tools that differ between GNU (Linux) and BSD (macOS) userlands. Sourced; defines functions only.
# FIXTURE (#171): was scripts/lib/portable.sh; only the Bash reference fixtures (stack.bash.sh, deploy-bash.sh) use it.

mtime() {  # mtime <path>: the modification time in epoch seconds; fails when the path cannot be read
  local t
  t="$(stat -c %Y "$1" 2>/dev/null)" && [ -n "$t" ] && { echo "$t"; return 0; }
  t="$(stat -f %m "$1" 2>/dev/null)" && [ -n "$t" ] && { echo "$t"; return 0; }
  t="$(date -r "$1" +%s 2>/dev/null)" && [ -n "$t" ] && { echo "$t"; return 0; }
  python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1" 2>/dev/null
}

_kill_tree() {  # _kill_tree <pid>: the process and all its descendants
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _kill_tree "$c"; done
  kill -KILL "$1" 2>/dev/null
}

run_bounded() {  # run_bounded <seconds> <command...>: the command's exit code, or 124 when it was stopped at its limit
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return; fi
  local pid watcher rc flag; flag="$(mktemp)"
  "$@" & pid=$!
  ( sleep "$secs"; echo hit > "$flag"; _kill_tree "$pid" ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  [ -s "$flag" ] && rc=124
  rm -f "$flag"; return "$rc"
}
