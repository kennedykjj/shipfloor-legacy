#!/usr/bin/env bash
# dispatch.sh takes limits from the project config, respects a machine-wide run limit across
# projects, and hands the pipeline only the directories and settings it needs.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export MYLOS_HOME="$(mktemp -d)"
  export FACTORY_HOME="$MYLOS_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" Q_DEV= Q_REF=
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 $2" in
  "eligible Ready for Dev") for n in ${Q_DEV:-}; do echo "$n"; done ;;
  "eligible Ready for Refinement") for n in ${Q_REF:-}; do echo "$n"; done ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat) $* | cfg=$FACTORY_CONFIG proj=$FACTORY_PROJECT mf=${MYLOS_FACTORY:-} snap=${FACTORY_BOARD_SNAPSHOT:-none}" >> "%s/launched"\nsleep 2\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
}
launched() { cat "$tmp/launched"; }
live_lock() { mkdir -p "$1"; echo "$$ $(date +%s) 1" > "$1/info"; }

# limits come from the config
setup; cfg="$(mktemp)"; cat "$FACTORY_CONFIG" > "$cfg"; printf 'limits:\n  develop: {parallel: 1}\n' >> "$cfg"; export FACTORY_CONFIG="$cfg"
Q_DEV="26 27" run_dispatch; out="$(launched)"
assert_contains "$out" "/mylos:develop 26"
case "$out" in *"develop 27"*) fail "ignored limits.develop.parallel: $out" ;; *) pass "parallel limit from config" ;; esac

# a machine-wide limit counts live runs of every project
setup; export MYLOS_MAX_PARALLEL=1; live_lock "$MYLOS_HOME/projects/other/locks/develop-9.lock"
Q_DEV="26" run_dispatch; [ -z "$(launched)" ] && pass "global limit across projects" || fail "launched past the global limit: $(launched)"
setup; export MYLOS_MAX_PARALLEL=2; live_lock "$MYLOS_HOME/projects/other/locks/develop-9.lock"
Q_DEV="26 27" run_dispatch; out="$(launched)"; assert_contains "$out" "develop 26"
case "$out" in *"develop 27"*) fail "two runs with one global slot: $out" ;; *) pass "one global slot → one run" ;; esac
unset MYLOS_MAX_PARALLEL

# the run gets the worktrees, its tmp and reviews dirs, the project's settings, and the factory flag
setup; Q_REF=25 run_dispatch; out="$(launched)"
assert_contains "$out" "/mylos:refine 25"
assert_contains "$out" "--add-dir $FACTORY_WT_ROOT"
assert_contains "$out" "--add-dir $FACTORY_HOME/tmp"
assert_contains "$out" "--add-dir $FACTORY_HOME/reviews"
case "$out" in *"--add-dir $FACTORY_HOME "*) fail "whole project home is writable" ;; *) pass "project home not added" ;; esac
assert_contains "$out" "cfg=$FACTORY_CONFIG proj=shop mf=1"
assert_contains "$out" "snap=none"   # a run reads the live board, never the cycle's snapshot

# an invalid config dispatches nothing
setup; bad="$(mktemp)"; echo 'project: {name: shop}' > "$bad"; export FACTORY_CONFIG="$bad"
Q_REF=25 run_dispatch; code=$?
[ -z "$(launched)" ] && [ "$code" -ne 0 ] && pass "invalid config → nothing, non-zero" || fail "dispatched with an invalid config (exit $code)"
finish
