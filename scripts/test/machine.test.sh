#!/usr/bin/env bash
# ~/.mylos/config.yml: the machine-wide agent pool and the runs each stage may take.
source "$(dirname "$0")/lib.sh"
export MYLOS_HOME="$(mktemp -d)"
m() { bash -c "source '$FACTORY_DIR/lib/project.sh'; mylos_machine \"\$@\"" _ "$@"; }
vals() { m values pool stages.refinar stages.desenvolver stages.validar stages.deployar | tr '\0' ' '; }

[ "$(vals)" = "4 2 2 2 1 " ] && pass "defaults without a file" || fail "defaults: $(vals)"
assert_exit 0 m validate

printf 'pool: 6\nstages: {desenvolver: 3}\n' > "$MYLOS_HOME/config.yml"
[ "$(vals)" = "6 2 3 2 1 " ] && pass "values merged with defaults" || fail "values: $(vals)"

bad() { printf '%s\n' "$1" > "$MYLOS_HOME/config.yml"; assert_exit 1 m validate; }
bad 'pool: 0'
bad 'pool: two'
bad $'pool: 2\nstages: {desenvolver: 3}'
bad $'pool: 4\nstages: {review: 1}'
bad $'pool: 4\nstages: {refinar: -1}'
bad 'stages: 3'
bad '[unclosed'
assert_exit 2 m values pool   # an unusable machine config is never read as a limit

printf '# my machine\npool: 4\nstages: {refinar: 1}\n' > "$MYLOS_HOME/config.yml"
assert_exit 0 m set pool 6
assert_exit 0 m set stages.validar 3
[ "$(vals)" = "6 1 2 3 1 " ] && pass "set keeps the other values" || fail "after set: $(vals)"
assert_exit 1 m set stages.validar 9      # above the pool
assert_exit 1 m set stages.review 1       # unknown stage
assert_exit 1 m set pool x
[ "$(vals)" = "6 1 2 3 1 " ] && pass "rejected sets change nothing" || fail "changed by a rejected set: $(vals)"
finish
