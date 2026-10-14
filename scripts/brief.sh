#!/usr/bin/env bash
# Builds <reviews>/<n>.brief.json for a card reaching Spec Review or Staged. The logic is shipfloor_core/brief.py.
# usage: brief.sh build <n> --column "Spec Review"|Staged --spec <spec> --head <sha> --notes <file> [--since <json>] [--out <file>]
set -- brief "$@"
HERE="${0%[/\\]*}"; [ "$HERE" != "$0" ] || HERE=.
source "$HERE/lib/py.sh"
