#!/usr/bin/env bash
# When a pipeline run ends, the dispatcher releases a stack lock that run left behind.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks"
tmp="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Dev") echo 26 ;; *) echo ;; esac\n' > "$tmp/board"
printf '#!/usr/bin/env bash\nmkdir -p "%s/locks/stack.lock"; echo "desenvolver-26 $(date +%%s)" > "%s/locks/stack.lock/info"\n' "$FACTORY_HOME" "$FACTORY_HOME" > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
bash "$D"; sleep 2
[ ! -d "$FACTORY_HOME/locks/stack.lock" ] && pass "leftover stack lock released" || fail "stack lock left by the run"
mkdir -p "$FACTORY_HOME/locks/stack.lock"; echo "desenvolver-99 $(date +%s)" > "$FACTORY_HOME/locks/stack.lock/info"
printf '#!/usr/bin/env bash\ntrue\n' > "$tmp/claude"; bash "$D"; sleep 2
[ -d "$FACTORY_HOME/locks/stack.lock" ] && pass "other run's stack lock kept" || fail "released another run's lock"
finish
