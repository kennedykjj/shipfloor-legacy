#!/usr/bin/env bash
# Entry point for the scheduled task (copied to ~/.pickio-factory by install-dispatcher.ps1).
# Brings the control checkout to origin/main, then runs that version of the dispatcher.
R="${FACTORY_REPO:-/c/Users/Kj/git/pickio}"
H="${FACTORY_HOME:-$HOME/.pickio-factory}"
C="$H/control"
mkdir -p "$H/logs"
exec >>"$H/logs/dispatcher.log" 2>&1
[ -e "$H/PAUSE" ] && exit 0
git -C "$R" fetch -q origin main || exit 1
[ -e "$C/.git" ] || git -C "$R" worktree add -q --detach "$C" origin/main || exit 1
# only touch the control checkout when main moved (pipelines run inside it and hold index.lock)
if [ "$(git -C "$C" rev-parse HEAD 2>/dev/null)" != "$(git -C "$R" rev-parse origin/main)" ]; then
# a pipeline running inside the control checkout may hold index.lock for a moment: retry
for try in 1 2 3; do
  git -C "$C" reset -q --hard origin/main && git -C "$C" clean -qfdx && break
  [ "$try" = 3 ] && exit 1
  sleep 5
done
fi
[ -f "$C/scripts/factory/dispatch.sh" ] || { echo "$(date -Is) dispatch.sh not on origin/main yet"; exit 0; }
FACTORY_CONTROL_REFRESH=0 bash "$C/scripts/factory/dispatch.sh"
