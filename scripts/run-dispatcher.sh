#!/usr/bin/env bash
# Entry point for the scheduled task (installed in ~/.shipfloor/factory by `shipfloor install`).
H="${SHIPFLOOR_HOME:-$HOME/.shipfloor}"
mkdir -p "$H/logs" "$H/tmp"
export TMPDIR="$H/tmp"
exec >>"$H/logs/dispatcher.log" 2>&1
[ -e "$H/PAUSE" ] && exit 0
[ -s "$H/dispatcher.path" ] && PATH="$(head -n1 "$H/dispatcher.path"):$PATH"
exec bash "$(dirname "$0")/shipfloor-dispatch.sh"
