#!/usr/bin/env bash
# Entry point for the scheduled task (installed in ~/.mylos/factory by `mylos install`).
H="${MYLOS_HOME:-$HOME/.mylos}"
mkdir -p "$H/logs"
exec >>"$H/logs/dispatcher.log" 2>&1
[ -e "$H/PAUSE" ] && exit 0
exec bash "$(dirname "$0")/mylos-dispatch.sh"
