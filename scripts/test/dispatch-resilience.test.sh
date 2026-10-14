#!/usr/bin/env bash
# Orphaned cards resume, the dispatcher backs off after a usage limit, and leftover processes are cleaned.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export FACTORY_HOME="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" Q_DEV= O_COD= O_VAL= W_CV=0 INFRA= BOARD_ERR=
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"; rm -f "$SHIPFLOOR_HOME/github-limited"
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "count Coding") echo "${W_CV:-0}" ;;
  "eligible Ready for Dev") for n in ${Q_DEV:-}; do echo "$n"; done ;;
  "eligible Coding") for n in ${O_COD:-}; do echo "$n"; done ;;
  "eligible Validation") for n in ${O_VAL:-}; do echo "$n"; done ;;
  "infra "*) for n in ${INFRA:-}; do echo "$n"; done ;;
  "label "*) echo "$*" >> "$FACTORY_HOME/labels" ;;
  "snapshot ") echo read >> "$FACTORY_HOME/reads"; [ -z "${BOARD_ERR:-}" ] || { echo "$BOARD_ERR" >&2; exit 1; }; echo ;;
  *) echo ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat) $* retry=${SHIPFLOOR_INFRA_RETRY:-0}" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
}
launched() { grep -o '/sf:[a-z]* [0-9]*' "$tmp/launched" | sort | tr '\n' ' '; }

# orphan in Coding (no live lock) resumes; it already counts toward WIP
setup; O_COD="42" W_CV=1; run_dispatch; assert_contains "$(launched)" "/sf:develop 42"
# orphan resumes before new cards; both fit in 2 runs
setup; O_COD="42" Q_DEV="60" W_CV=1; run_dispatch; out="$(launched)"; assert_contains "$out" "/sf:develop 42"; assert_contains "$out" "/sf:develop 60"
# two Coding orphans fill develop's 2 runs: no new card; a Validation card goes to validate
setup; O_COD="42 43" O_VAL="54" Q_DEV="60" W_CV=2; run_dispatch; out="$(launched)"; assert_contains "$out" "/sf:develop 42 /sf:develop 43"
case "$out" in *60*) fail "started a new card with both runs busy" ;; *) pass "runs respected with orphans" ;; esac
assert_contains "$out" "/sf:validate 54"
# usage limit: a run that ended with "session limit" in the last 30 min pauses launches
setup; Q_DEV="60"; printf '== start /sf:develop 54\nYou'"'"'ve hit your session limit · resets 6:10pm\n== end /sf:develop 54 exit=1\n' > "$FACTORY_HOME/logs/$(date +%F)-54-develop.log"
run_dispatch; [ -z "$(launched)" ] && pass "backs off after a usage limit" || fail "launched during usage limit"
touch -d '-40 minutes' "$FACTORY_HOME/logs/$(date +%F)-54-develop.log"
run_dispatch; assert_contains "$(launched)" "/sf:develop 60"
# GitHub API limit (#190): a board read refused for it marks the machine; while the mark is fresh no cycle reads the board or launches
reads() { cat "$FACTORY_HOME/reads" 2>/dev/null | wc -l | tr -d ' '; }
setup; Q_DEV="60"; BOARD_ERR="GraphQL: API rate limit already exceeded for user ID 1"; run_dispatch
[ -e "$SHIPFLOOR_HOME/github-limited" ] && pass "a refused board read marks the GitHub limit" || fail "no github-limited mark"
BOARD_ERR=; run_dispatch
[ -z "$(launched)" ] && pass "no launch while GitHub limits the account" || fail "launched during the GitHub limit: $(launched)"
[ "$(reads)" = 1 ] && pass "no board read while the mark is fresh" || fail "read the board $(reads) times"
touch -d '-11 minutes' "$SHIPFLOOR_HOME/github-limited"; run_dispatch; assert_contains "$(launched)" "/sf:develop 60"
touch -d '-20 minutes' "$SHIPFLOOR_HOME/github-limited"; : > "$tmp/launched"; SHIPFLOOR_GITHUB_LIMIT_MIN=30 run_dispatch
[ -z "$(launched)" ] && pass "SHIPFLOOR_GITHUB_LIMIT_MIN sets the window" || fail "launched inside a 30-minute window"
setup; Q_DEV="60"; BOARD_ERR="gh: Could not resolve to a ProjectV2"; run_dispatch
[ ! -e "$SHIPFLOOR_HOME/github-limited" ] && pass "another board error leaves no mark" || fail "marked on a non-limit error"
setup; Q_DEV="60"; BOARD_ERR="You have exceeded a secondary rate limit"; run_dispatch
[ -e "$SHIPFLOOR_HOME/github-limited" ] && pass "a secondary rate limit marks too" || fail "no mark on a secondary rate limit"
rm -f "$SHIPFLOOR_HOME/github-limited"
# blocked:infra: cleaned (tmp/<n>/ goes), label removed, relaunched once with SHIPFLOOR_INFRA_RETRY=1
setup; INFRA="70" O_VAL="70"; mkdir -p "$FACTORY_HOME/tmp/70/junk"; run_dispatch
assert_contains "$(cat "$FACTORY_HOME/labels" 2>/dev/null)" "label 70 remove blocked:infra"
assert_contains "$(grep '/sf:validate 70 ' "$tmp/launched")" "retry=1"
[ ! -e "$FACTORY_HOME/tmp/70" ] && pass "infra leftovers cleaned" || fail "tmp/70 kept"
[ -e "$FACTORY_HOME/infra/70" ] && pass "the retry's marker outlives the retried run" || fail "marker cleared by the retried run"
# next cycle: the card is no longer blocked:infra, so the marker goes
INFRA=""; run_dispatch; [ ! -e "$FACTORY_HOME/infra/70" ] && pass "stale marker cleared" || fail "marker kept after the block cleared"
# a card already retried and blocked by infrastructure again goes to the owner, not relaunched
setup; INFRA="71"; mkdir -p "$FACTORY_HOME/infra"; date +%s > "$FACTORY_HOME/infra/71"; run_dispatch
assert_contains "$(cat "$FACTORY_HOME/labels" 2>/dev/null)" "label 71 add blocked"
case "$(cat "$tmp/launched")" in *71*) fail "relaunched a card whose retry failed" ;; *) pass "second infra block goes to the owner" ;; esac
finish
