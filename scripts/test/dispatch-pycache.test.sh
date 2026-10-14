#!/usr/bin/env bash
# A dispatch cycle that computes cost runs dashboard_cost.py from the installed factory; it must not write
# __pycache__ there (the installed copy would then differ from what was installed).
source "$(dirname "$0")/lib.sh"
unset PYTHONDONTWRITEBYTECODE
inst="$(plugin_copy)"; D="$inst/scripts/dispatch.sh"
export SHIPFLOOR_HOME="$(mktemp -d)"
export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" CLAUDE_CONFIG_DIR="$(mktemp -d)"
tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
printf 'pool: 4\ncosts:\n  card_block: 40\n  day_stop: 500\n' > "$SHIPFLOOR_HOME/config.yml"
printf '#!/usr/bin/env bash\ncase "$1 ${2:-}" in "count "*) echo 0 ;; *) echo ;; esac\n' > "$tmp/board"
chmod +x "$tmp/board"; export FACTORY_BOARD="$tmp/board"
[ -z "$(find "$inst" -name __pycache__)" ] && pass "AC-8 the installed copy starts clean" || fail "AC-8 the copy already has a __pycache__"

run_dispatch >/dev/null 2>&1
found="$(find "$inst" -name __pycache__ -o -name '*.pyc')"
[ -z "$found" ] && pass "AC-8 a cycle that computes cost leaves no __pycache__ in the installed factory" || fail "AC-8 bytecode written under the installed factory:
$found"
finish
