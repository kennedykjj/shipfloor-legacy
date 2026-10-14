#!/usr/bin/env bash
# usage_limited reads every log whole, whatever the path: a SHIPFLOOR_HOME with a space gives the same verdict
# as one without.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {  # setup <home dir name>
  export SHIPFLOOR_HOME="$(mktemp -d)/$1"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  printf '#!/usr/bin/env bash\ncase "$1 ${2:-}" in "eligible Ready for Dev") echo 26 ;; "count "*) echo 0 ;; *) echo ;; esac\n' > "$tmp/board"
  printf '#!/usr/bin/env bash\necho "$(cat)" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
  : > "$tmp/launched"
}
limit_log() { printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit · resets 6pm\n' > "$FACTORY_HOME/logs/$(date +%F)-5-develop.log"; }

for name in plain "with space"; do
  # a recent run ended on the usage limit: nothing starts
  setup "$name"; limit_log; run_dispatch >/dev/null 2>&1
  [ -z "$(cat "$tmp/launched")" ] && pass "AC-4 usage limit pauses the launches (home '$name')" || fail "AC-4 launched during a usage limit (home '$name'): $(cat "$tmp/launched")"
  # a log without the limit: the card starts
  setup "$name"; printf '== start /sf:develop 5\nall fine\n' > "$FACTORY_HOME/logs/$(date +%F)-5-develop.log"; run_dispatch >/dev/null 2>&1
  case "$(cat "$tmp/launched")" in *"/sf:develop 26"*) pass "AC-4 a log without the limit lets the card start (home '$name')" ;; *) fail "AC-4 nothing launched (home '$name')" ;; esac
  # the limit followed by a later start in the same log is over
  setup "$name"; printf '%s\n' "You've hit your session limit" '== start /sf:develop 5' 'running' > "$FACTORY_HOME/logs/$(date +%F)-5-develop.log"; run_dispatch >/dev/null 2>&1
  case "$(cat "$tmp/launched")" in *"/sf:develop 26"*) pass "AC-4 only the last run of a log counts (home '$name')" ;; *) fail "AC-4 an old limit paused the launches (home '$name')" ;; esac
done
finish
