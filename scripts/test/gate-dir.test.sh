#!/usr/bin/env bash
# gate.sh -C <worktree> runs against that worktree from any directory.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
r="$(new_repo)"; base="$(git -C "$r" rev-parse HEAD)"; mkdir -p "$r/web"; echo x > "$r/web/a.ts"
cd "$(mktemp -d)"
assert_exit 0 bash "$GATE" -C "$r" scope web "$base"
assert_exit 1 bash "$GATE" -C "$r" scope api "$base"
assert_exit 2 bash "$GATE" -C /nonexistent scope api "$base"
finish
