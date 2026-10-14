#!/usr/bin/env bash
# A run that cannot enter the control checkout (the directory is gone) ends with an error and leaves no lock:
# a lock left behind would hold the card's slot until it expired.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export SHIPFLOOR_HOME="$(mktemp -d)"
export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
tmp="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$1 ${2:-}" in "eligible Ready for Dev") echo 26 ;; "count "*) echo 0 ;; *) echo ;; esac\n' > "$tmp/board"
printf '#!/usr/bin/env bash\necho "$(cat)" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
mkdir -p "$FACTORY_HOME"; [ ! -e "$FACTORY_HOME/control" ] || rm -rf "$FACTORY_HOME/control"

run_dispatch >/dev/null 2>&1
[ -z "$(cat "$tmp/launched")" ] && pass "AC-6 no agent starts without a control checkout" || fail "AC-6 an agent started: $(cat "$tmp/launched")"
[ ! -e "$FACTORY_HOME/locks/develop-26.lock" ] && pass "AC-6 the run that could not cd leaves no lock behind" || fail "AC-6 lock left behind: $(cat "$FACTORY_HOME/locks/develop-26.lock/info" 2>/dev/null)"
# the next cycle, with the checkout back, is free to start the card
mkdir -p "$FACTORY_HOME/control"; run_dispatch >/dev/null 2>&1
case "$(cat "$tmp/launched")" in *"/sf:develop 26"*) pass "AC-6 the card starts on the next cycle" ;; *) fail "AC-6 the card did not start once the checkout was back" ;; esac
finish
