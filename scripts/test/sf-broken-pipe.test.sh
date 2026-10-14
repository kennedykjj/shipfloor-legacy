#!/usr/bin/env bash
# sf.py ends quietly when the reader of its stdout goes away, as the Bash scripts it replaced did on SIGPIPE: the
# dispatcher's health record starts `board.sh snapshot` in a thread and exits without reading it.
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)" || exit 1
big="$T/big"; for i in $(seq 1 20000); do printf '%s\tCoding\tPVTI_%s\n' "$i" "$i"; done > "$big"
# a command that prints a lot: board.sh items reading a snapshot file
FACTORY_BOARD_SNAPSHOT="$big" FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" \
  bash "$FACTORY_DIR/board.sh" items 2>"$T/err" | head -1 >/dev/null
rc=${PIPESTATUS[0]}
[ ! -s "$T/err" ] && pass "a closed reader prints no traceback" || fail "stderr: $(head -3 "$T/err")"
[ "$rc" = 141 ] || [ "$rc" = 0 ] && pass "it ends with 141 (or 0 when it finished first)" || fail "exit $rc"
finish
