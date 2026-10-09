#!/usr/bin/env bash
# Orphaned cards resume, the dispatcher backs off after a usage limit, and leftover processes are cleaned.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export FACTORY_HOME="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" Q_DEV= O_COD= O_VAL= W_CV=0
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 $2" in
  "count Coding") echo "${W_CV:-0}" ;;
  "eligible Ready for Dev") for n in ${Q_DEV:-}; do echo "$n"; done ;;
  "eligible Coding") for n in ${O_COD:-}; do echo "$n"; done ;;
  "eligible Validation") for n in ${O_VAL:-}; do echo "$n"; done ;;
  *) echo ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat) $*" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
}
launched() { sleep 1; grep -o '/mylos:[a-z]* [0-9]*' "$tmp/launched" | sort | tr '\n' ' '; }

# orphan in Coding (no live lock) resumes; it already counts toward WIP
setup; O_COD="42" W_CV=1; bash "$D"; assert_contains "$(launched)" "/mylos:develop 42"
# orphan resumes before new cards; both fit in 2 runs
setup; O_COD="42" Q_DEV="60" W_CV=1; bash "$D"; out="$(launched)"; assert_contains "$out" "/mylos:develop 42"; assert_contains "$out" "/mylos:develop 60"
# two Coding orphans fill develop's 2 runs: no new card; a Validation card goes to validate
setup; O_COD="42 43" O_VAL="54" Q_DEV="60" W_CV=2; bash "$D"; out="$(launched)"; assert_contains "$out" "/mylos:develop 42 /mylos:develop 43"
case "$out" in *60*) fail "started a new card with both runs busy" ;; *) pass "runs respected with orphans" ;; esac
assert_contains "$out" "/mylos:validate 54"
# usage limit: a run that ended with "session limit" in the last 30 min pauses launches
setup; Q_DEV="60"; printf '== start /mylos:develop 54\nYou'"'"'ve hit your session limit · resets 6:10pm\n== end /mylos:develop 54 exit=1\n' > "$FACTORY_HOME/logs/$(date +%F)-54-develop.log"
bash "$D"; [ -z "$(launched)" ] && pass "backs off after a usage limit" || fail "launched during usage limit"
touch -d '-40 minutes' "$FACTORY_HOME/logs/$(date +%F)-54-develop.log"
bash "$D"; assert_contains "$(launched)" "/mylos:develop 60"
finish
