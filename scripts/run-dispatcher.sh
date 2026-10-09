#!/usr/bin/env bash
# Entry point for the scheduled task (installed in ~/.aghanim/factory by `aghanim install`).
H="${AGHANIM_HOME:-$HOME/.aghanim}"
mkdir -p "$H/logs"
exec >>"$H/logs/dispatcher.log" 2>&1
[ -e "$H/PAUSE" ] && exit 0
exec bash "$(dirname "$0")/aghanim-dispatch.sh"
