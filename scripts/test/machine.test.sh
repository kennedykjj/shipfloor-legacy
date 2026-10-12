#!/usr/bin/env bash
# ~/.shipfloor/config.yml: the machine-wide agent pool and the runs each stage may take.
source "$(dirname "$0")/lib.sh"
export SHIPFLOOR_HOME="$(mktemp -d)"
m() { bash -c "source '$FACTORY_DIR/lib/project.sh'; shipfloor_machine \"\$@\"" _ "$@"; }
vals() { m values pool stages.refine stages.develop stages.validate stages.deploy | tr '\0' ' '; }

[ "$(vals)" = "4 2 2 2 1 " ] && pass "defaults without a file" || fail "defaults: $(vals)"
assert_exit 0 m validate

printf 'pool: 6\nstages: {develop: 3}\n' > "$SHIPFLOOR_HOME/config.yml"
[ "$(vals)" = "6 2 3 2 1 " ] && pass "values merged with defaults" || fail "values: $(vals)"

bad() { printf '%s\n' "$1" > "$SHIPFLOOR_HOME/config.yml"; assert_exit 1 m validate; }
bad 'pool: 0'
bad 'pool: two'
bad $'pool: 2\nstages: {develop: 3}'
bad $'pool: 4\nstages: {review: 1}'
bad $'pool: 4\nstages: {refine: -1}'
bad 'stages: 3'
bad '[unclosed'
assert_exit 2 m values pool   # an unusable machine config is never read as a limit

printf '# my machine\npool: 4\nstages: {refine: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
assert_exit 0 m set pool 6
assert_exit 0 m set stages.validate 3
[ "$(vals)" = "6 1 2 3 1 " ] && pass "set keeps the other values" || fail "after set: $(vals)"
assert_exit 1 m set stages.validate 9      # above the pool
assert_exit 1 m set stages.review 1       # unknown stage
assert_exit 1 m set pool x
[ "$(vals)" = "6 1 2 3 1 " ] && pass "rejected sets change nothing" || fail "changed by a rejected set: $(vals)"
# stack slots and their timers have defaults and are validated like the pool
rm -f "$SHIPFLOOR_HOME/config.yml"
assert_contains "$(m values stacks ports.base ports.span stack_wait stack_stale stack_hold_max | tr '\0' ' ')" "3 20000 20 1800 90 2700"
bad 'stacks: 0'
bad 'ports: {base: 70000, span: 20}'
bad 'stack_wait: x'

# costs: optional limits in US$, no defaults; each a number > 0, card_warn <= card_block, no other key
cv() { m values costs.card_warn costs.card_block costs.day_stop | tr '\0' '|'; }
good() { printf '%s\n' "$1" > "$SHIPFLOOR_HOME/config.yml"; assert_exit 0 m validate; }
rm -f "$SHIPFLOOR_HOME/config.yml"
[ "$(cv)" = "|||" ] && pass "AC-7 no costs: every limit reads empty" || fail "AC-7 costs without a file: $(cv)"
good $'costs:\n  card_warn: 20\n  card_block: 40\n  day_stop: 80'
[ "$(cv)" = "20|40|80|" ] && pass "AC-8 the three limits read back" || fail "AC-8 costs values: $(cv)"
good $'costs:\n  card_warn: 12.5\n  card_block: 40.25\n  day_stop: 80.5'
[ "$(cv)" = "12.5|40.25|80.5|" ] && pass "AC-8 amounts may have decimals" || fail "AC-8 decimal costs: $(cv)"
good $'costs:\n  day_stop: 80'
[ "$(cv)" = "||80|" ] && pass "AC-7 only some keys: the others read empty" || fail "AC-7 partial costs: $(cv)"
good $'costs:\n  card_warn: 20'
good $'costs:\n  card_block: 40'
good $'costs:\n  card_warn: 40\n  card_block: 40'   # equal is allowed: warn <= block
good $'pool: 4\ncosts: {}'
bad $'costs:\n  card_warn: 0'
bad $'costs:\n  card_block: -5'
bad $'costs:\n  day_stop: 0'
bad $'costs:\n  day_stop: lots'
bad $'costs:\n  card_block: true'
bad $'costs:\n  card_warn: [20]'
bad $'costs:\n  card_warn: 50\n  card_block: 40'   # the warning above the block
bad $'costs:\n  card_stop: 10'                      # unknown key
bad $'costs:\n  day_stop: 80\n  daily: 5'
bad 'costs: 5'
bad $'costs:\n  - 10'
printf 'costs:\n  card_warn: 50\n  card_block: 40\n' > "$SHIPFLOOR_HOME/config.yml"
assert_contains "$(m validate 2>&1)" "costs"
assert_exit 2 m values costs.card_block   # an invalid costs section is never read as a limit
printf 'costs:\n  card_warn: 0\n' > "$SHIPFLOOR_HOME/config.yml"
assert_contains "$(m validate 2>&1)" "costs"
finish
