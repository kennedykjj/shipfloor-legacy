#!/usr/bin/env bash
# What cards leave under the project's tmp/ is removed without anyone asking: by `aghanim clean` and at
# the end of every dispatcher cycle.
source "$(dirname "$0")/lib.sh"
source "$FACTORY_DIR/lib/project.sh"
D="$FACTORY_DIR/dispatch.sh"
T="$FACTORY_HOME/tmp"
old() { touch -d '5 days ago' "$@"; }
setup() {
  rm -rf "$FACTORY_HOME"; mkdir -p "$T" "$FACTORY_HOME/locks"
  printf '5\tDone\tI5\n6\tCoding\tI6\n7\tDone\tI7\n' > "$FACTORY_HOME/board.tsv"
}
left() { ls "$T" | tr '\n' ' '; }

# the tmp/<n>/ of a card that is Done or off the board goes; an active card's and a running one's stay
setup; mkdir -p "$T/5/x" "$T/6/x" "$T/7" "$T/8"; mkdir "$FACTORY_HOME/locks/deploy-7.lock"
out="$(aghanim_sweep_tmp | tr '\n' ' ')"
assert_contains "$out" "tmp/5 tmp/8"
[ "$(left)" = "6 7 " ] && pass "keeps the active and the running card" || fail "left: $(left)"

# loose files and folders beside the card folders go once nobody touched them for 3 days
setup; echo x > "$T/green.txt"; mkdir -p "$T/ux5"; echo x > "$T/ux5/a.png"; echo x > "$T/5-pw.txt"; echo x > "$T/fresh.txt"
old "$T/green.txt" "$T/ux5/a.png" "$T/ux5" "$T/5-pw.txt"
aghanim_sweep_tmp >/dev/null
[ "$(left)" = "fresh.txt " ] && pass "old strays go, a fresh one stays" || fail "left: $(left)"
# a folder is as fresh as the newest file in it
setup; mkdir -p "$T/ux5"; echo x > "$T/ux5/old.png"; old "$T/ux5/old.png" "$T/ux5"; echo x > "$T/ux5/new.png"
aghanim_sweep_tmp >/dev/null; [ -e "$T/ux5/old.png" ] && pass "a folder with a fresh file stays whole" || fail "removed a folder in use"
# a stray that carries the number of a card still in progress stays, however old
setup; echo x > "$T/6-build.log"; echo x > "$T/v6-shot.png"; mkdir "$T/ux6"; old "$T"/*
aghanim_sweep_tmp >/dev/null
[ "$(left)" = "6-build.log ux6 v6-shot.png " ] && pass "an active card's strays stay" || fail "left: $(left)"

# with no board read nothing goes: every card would look gone
setup; mkdir -p "$T/6"; echo x > "$T/green.txt"; old "$T/green.txt"; printf '\n' > "$FACTORY_HOME/board.tsv"
aghanim_sweep_tmp >/dev/null; [ "$(left)" = "6 green.txt " ] && pass "an empty board removes nothing" || fail "left: $(left)"
rm "$FACTORY_HOME/board.tsv"
aghanim_sweep_tmp >/dev/null; [ "$(left)" = "6 green.txt " ] && pass "no board file removes nothing" || fail "left: $(left)"

# the dispatcher does it at the end of every cycle, and gives a run its tmp/<n>/ before it starts
setup; export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"; b="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$T/5"; echo x > "$T/green.txt"; old "$T/green.txt"
cat > "$b/board" <<'EOB'
#!/usr/bin/env bash
case "$1 $2" in
  "snapshot "*) printf '5\tDone\tI5\n26\tReady for Dev\tI26\n' ;;
  "eligible Ready for Dev") echo 26 ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
printf '#!/usr/bin/env bash\n[ -d "%s/26" ] && echo yes > "%s/had-tmp"\n' "$T" "$b" > "$b/claude"
chmod +x "$b/board" "$b/claude"; export FACTORY_BOARD="$b/board" FACTORY_CLAUDE="$b/claude"
out="$(run_dispatch 2>&1)"
assert_contains "$out" "dispatch: removed tmp/5"
assert_contains "$out" "dispatch: removed tmp/green.txt"
[ -s "$b/had-tmp" ] && pass "the run found its tmp/<n>/" || fail "no tmp/26 when the run started"
finish
