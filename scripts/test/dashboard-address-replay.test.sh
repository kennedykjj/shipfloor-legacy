#!/usr/bin/env bash
# suite: unit
# fromAddress (#183): the `else if` that moves the replay to a time hash (#@0940) must not sit inside a `//` comment.
source "$(dirname "$0")/lib.sh"
line="$(grep -n 'if (m == null) { if (R.at' "$FACTORY_DIR/dashboard.html" | head -1)"
if [ -z "$line" ]; then fail "fromAddress line not found"
else
  case "$line" in
    *//*else\ if*) fail "fromAddress: the else if is inside a // comment" ;;
    *'} else if (!R.at || atMin() !== m) needle(m, "key", true);'*) pass "fromAddress keeps the else if as code" ;;
    *) fail "fromAddress: the else if is missing: $line" ;;
  esac
fi
finish
