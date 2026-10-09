#!/usr/bin/env bash
# The pipeline prompt reaches claude unmangled (no MSYS path conversion) and every run is logged.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
tmp="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Dev") echo 54 ;; *) echo ;; esac\n' > "$tmp/board"
printf '#!/usr/bin/env bash\necho "pathconv=${MSYS_NO_PATHCONV:-unset} prompt=$(cat)"\nexit 3\n' > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
bash "$D"; sleep 2
log="$(cat "$FACTORY_HOME"/logs/*-54-desenvolver.log)"
assert_contains "$log" "pathconv=unset prompt=/desenvolver 54"
assert_contains "$log" "== start /desenvolver 54"
assert_contains "$log" "== end /desenvolver 54 exit=3"
finish
