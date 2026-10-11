#!/usr/bin/env bash
# When a run ends, the dispatcher releases the stack slot it still holds and removes its tmp/<n>/.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks"
tmp="$(mktemp -d)"; S="$SHIPFLOOR_HOME/locks"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Dev") echo 26 ;; *) echo ;; esac\n' > "$tmp/board"
cat > "$tmp/claude" <<'EOC'
#!/usr/bin/env bash
mkdir -p "$SHIPFLOOR_HOME/locks/stack-0.lock" "$FACTORY_HOME/tmp/26/scratch"
echo "develop-26 $SHIPFLOOR_RUN_LOCK $(date +%s)" > "$SHIPFLOOR_HOME/locks/stack-0.lock/info"
EOC
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
mkdir -p "$S/stack-1.lock"; echo "develop-99 $FACTORY_HOME/locks/develop-99.lock $(date +%s)" > "$S/stack-1.lock/info"
run_dispatch
[ ! -d "$S/stack-0.lock" ] && pass "the run's stack slot released" || fail "stack slot left by the run"
[ ! -e "$FACTORY_HOME/tmp/26" ] && pass "the run's tmp/26 removed" || fail "tmp/26 left by the run"
[ -d "$S/stack-1.lock" ] && pass "another run's slot kept" || fail "released another run's slot"
finish
