#!/usr/bin/env bash
# Entry point for the scheduled task (installed in ~/.shipfloor/factory by `shipfloor install`).
H="${SHIPFLOOR_HOME:-$HOME/.shipfloor}"
mkdir -p "$H/logs"
exec >>"$H/logs/dispatcher.log" 2>&1
[ -e "$H/PAUSE" ] && exit 0
exec bash "$(dirname "$0")/shipfloor-dispatch.sh"
