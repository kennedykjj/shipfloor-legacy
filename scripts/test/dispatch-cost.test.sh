#!/usr/bin/env bash
# Cost limits, the dispatcher's side: a card at costs.card_block is blocked instead of started, a day past
# costs.day_stop starts nothing until the local day changes, an unpriced card is never judged, and with no
# (or only some) of the limits set nothing changes. The estimate comes from fake Claude Code transcripts under a
# temp CLAUDE_CONFIG_DIR and a temp SHIPFLOOR_HOME: nothing here reads the real ~/.claude or ~/.shipfloor.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
CLI="$(nat "$FACTORY_DIR/dashboard_cost.py")"
# "today" is the machine's local date: do not straddle midnight
[ "$(date +%H%M)" -ge 2358 ] && sleep 150

setup() {
  export SHIPFLOOR_HOME="$(mktemp -d)"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" CLAUDE_CONFIG_DIR="$(nat "$(mktemp -d)")"
  unset SHIPFLOOR_MAX_PARALLEL
  export Q_REF= Q_DEV= Q_VAL= Q_PROD=
  tmp="$(mktemp -d)"; export COST_TMP="$tmp"
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs" "$SHIPFLOOR_HOME/projects/other"
  printf 'shop\t/x/shop\t/x/wt\tmain\nother\t/x/other\t/x/wt2\tmain\n' > "$SHIPFLOOR_HOME/registry.tsv"
  printf 'claude-opus-5-5: {input: 4.00, output: 20.00, cache_write_5m: 5.00, cache_write_1h: 8.00, cache_read: 0.20}\n' > "$SHIPFLOOR_HOME/prices.yml"
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Refinement") for n in ${Q_REF:-}; do echo "$n"; done ;;
  "eligible Ready for Dev") for n in ${Q_DEV:-}; do echo "$n"; done ;;
  "eligible Validation") for n in ${Q_VAL:-}; do echo "$n"; done ;;
  "eligible Ready for Prod") for n in ${Q_PROD:-}; do echo "$n"; done ;;
  "count "*) echo 0 ;;
  "label "*) echo "label $2 $3 $4" >> "$COST_TMP/events"; [ -e "$COST_TMP/label-fails" ] && exit 1; exit 0 ;;
  *) echo ;;
esac
EOB
  cat > "$tmp/gh" <<'EOG'
#!/usr/bin/env bash
echo "gh $*" >> "$COST_TMP/gh-calls"
if [ "$1 $2" = "issue comment" ]; then
  [ -e "$COST_TMP/comment-fails" ] && { echo "gh: HTTP 502" >&2; exit 1; }
  f=""; prev=""; n=""
  for a in "${@:3}"; do
    [ "$prev" = --body-file ] && f="$a"
    case "$a" in *[!0-9]*|"") ;; *) [ -z "$n" ] && n="$a" ;; esac
    prev="$a"
  done
  [ -n "$f" ] || { echo "fake-gh: no --body-file in: $*" >&2; exit 2; }
  c=$(( $(cat "$COST_TMP/ccount-$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$COST_TMP/ccount-$n"
  if [ "$f" = - ]; then cat > "$COST_TMP/comment-$n-$c"; else cp "$f" "$COST_TMP/comment-$n-$c"; fi
  echo "comment $n" >> "$COST_TMP/events"
  exit 0
fi
exit 0
EOG
  printf '#!/usr/bin/env bash\necho "$(cat)" >> "$COST_TMP/launched"\n' > "$tmp/claude"
  printf '#!/usr/bin/env bash\necho "deploy $1" >> "$COST_TMP/launched"\n' > "$tmp/deploy"
  chmod +x "$tmp/board" "$tmp/gh" "$tmp/claude" "$tmp/deploy"
  export FACTORY_BOARD="$tmp/board" FACTORY_GH="$tmp/gh" FACTORY_CLAUDE="$tmp/claude" FACTORY_DEPLOY="$tmp/deploy"
  : > "$tmp/launched"; : > "$tmp/events"
  machine ""
}
# room for every card a scenario queues: the machine's stage slots are not what these tests are about
POOLCFG=$'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}'
machine() { printf '%s\n%s\n' "$POOLCFG" "$1" > "$SHIPFLOOR_HOME/config.yml"; }
# tx <name> <issue> <stage> <US$> <today|yesterday> [model] [project]: one transcript of a session for a card, costing
# US$ at opus input prices ($4 per million tokens), started at noon of that local day
tx() {
  local d="$CLAUDE_CONFIG_DIR/projects/C--x--shipfloor-projects-${7:-shop}-control" day model="${6:-claude-opus-5-5}" tokens
  mkdir -p "$d"
  if [ "$5" = yesterday ]; then day="$(date -d yesterday +%F)"; else day="$(date +%F)"; fi
  tokens=$(( $4 * 250000 ))
  { printf '{"type":"user","timestamp":"%sT12:00:00%s","message":{"role":"user","content":"<command-name>/sf:%s</command-name>\\n<command-args>%s</command-args>"}}\n' "$day" "$(date +%:z)" "$3" "$2"
    printf '{"type":"assistant","timestamp":"%sT12:05:00%s","message":{"id":"m-%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":0}}}\n' "$day" "$(date +%:z)" "$1" "$model" "$tokens"
  } > "$d/$1.jsonl"
}
cycle() { OUT="$(run_dispatch 2>&1; echo "rc=$?")"; RC="${OUT##*rc=}"; }
reset() { : > "$tmp/launched"; : > "$tmp/events"; }
launched() { sort "$tmp/launched" | tr '\n' ' '; }
launched_has() { case "$(launched)" in *"$1"*) return 0 ;; esac; return 1; }
not() { ! "$@"; }
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
near() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a-b<0.01 && b-a<0.01)}'; }
jget() { "$FACTORY_PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$(nat "$1")" "$2" 2>/dev/null | tr -d '\r'; }
first() { head -n 1 "$1" | tr -d '\r'; }
lim() { "$FACTORY_PYTHON" -I "$CLI" limits --home "$(nat "$SHIPFLOOR_HOME")" --project shop --claude-dir "$CLAUDE_CONFIG_DIR" 2>/dev/null | tr -d '\r'; }
lim_has() { lim | grep -qx "$1"; }
day_field() { lim | awk -F'\t' -v n="$1" '$1=="day_stop"{print $n}'; }
live_lock() { mkdir -p "$FACTORY_HOME/locks/$1.lock"; echo "$$ $(date +%s) $2" > "$FACTORY_HOME/locks/$1.lock/info"; }
comment_before_label() {
  local c l
  c="$(grep -n "^comment $1\$" "$tmp/events" | head -n 1 | cut -d: -f1)"; l="$(grep -n "^label $1 add blocked\$" "$tmp/events" | head -n 1 | cut -d: -f1)"
  [ -n "$c" ] && [ -n "$l" ] && [ "$c" -lt "$l" ]
}
n_events() { grep -c "^$1\$" "$tmp/events"; }

# ---- AC-2: a card at card_block is not started; it is labeled blocked and told why
setup; machine $'costs:\n  card_block: 40'
tx s1 77 develop 30 today; tx s2 77 refine 11 today; tx s3 78 develop 5 today
Q_DEV="77 78"; cycle
t "AC-2 no run starts for a card whose estimate (41) is over card_block (40)" not launched_has "/sf:develop 77"
t "AC-2 a card under card_block still starts" launched_has "/sf:develop 78"
t "AC-2 the cycle itself succeeds" test "$RC" = 0
t "AC-2 the blocked card gets the blocked label" test "$(n_events 'label 77 add blocked')" = 1
t "AC-2 a card under the limit gets no label" not grep -q "label 78" "$tmp/events"
t "AC-2 one comment is posted, with --body-file, before the label" comment_before_label 77
t "AC-2 exactly one comment" test "$(n_events 'comment 77')" = 1
body="$tmp/comment-77-1"
t "AC-2 the comment opens with 'Cost limit: blocked.'" test "$(first "$body")" = "Cost limit: blocked."
t "AC-2 the comment gives the estimated total (41)" grep -q "41" "$body"
t "AC-2 the comment gives the limit (40)" grep -q "40" "$body"
t "AC-2 the comment labels the figures as an estimate" grep -qi "estimate" "$body"
t "AC-2 the comment has the develop stage with its 30" grep -Eq "develop.*30|30.*develop" "$body"
t "AC-2 the comment has the refine stage with its 11" grep -Eq "refine.*11|11.*refine" "$body"
m="$FACTORY_HOME/cost/77.json"
t "AC-2 the marker cost/77.json records the total" near "$(jget "$m" 'd["total"]')" 41
t "AC-2 the marker records the limit" near "$(jget "$m" 'd["limit"]')" 40
t "AC-2 the marker's baseline is 0 for a card never blocked" near "$(jget "$m" 'd["baseline"]')" 0
t "AC-2 the marker records the spend per stage" test "$(jget "$m" '[round(d["stages"]["develop"]), round(d["stages"]["refine"])]')" = "[30, 11]"
t "AC-2 the marker says when" test -n "$(jget "$m" 'd["at"]')"
t "AC-2 the card under the limit has no marker" test ! -e "$FACTORY_HOME/cost/78.json"

# a failed comment or label fails the cycle and the card is still not launched
setup; machine $'costs:\n  card_block: 40'; tx s1 77 develop 41 today; Q_DEV="77"; : > "$tmp/comment-fails"; cycle
t "AC-2 a failed comment fails the cycle" test "$RC" != 0
t "AC-2 a failed comment still does not launch the card" not launched_has "/sf:develop 77"
t "AC-2 a failed comment leaves no blocked label" not grep -q "^label 77" "$tmp/events"
setup; machine $'costs:\n  card_block: 40'; tx s1 77 develop 41 today; Q_DEV="77"; : > "$tmp/label-fails"; cycle
t "AC-2 a failed label fails the cycle" test "$RC" != 0
t "AC-2 a failed label still does not launch the card" not launched_has "/sf:develop 77"

# the limit acts at >= : a card that spent exactly card_block starts nothing more; one cent under does
setup; machine $'costs:\n  card_block: 40'; tx s1 77 develop 40 today; tx s2 78 develop 39 today; tx s3 5 develop 90 today "" other
t "AC-2 the limits CLI lists a card at exactly card_block" lim_has $'block\t77'
t "AC-2 the limits CLI does not list a card under it" not lim_has $'block\t78'
t "AC-2 the limits CLI lists only the project's own cards" not lim_has $'block\t5'

# ---- AC-3: unblocking lets the card spend up to card_block again, counted from the unblock
setup; machine $'costs:\n  card_block: 40'; tx s1 77 develop 30 today; tx s2 77 refine 11 today; Q_DEV="77"; cycle
m="$FACTORY_HOME/cost/77.json"
t "AC-3 first block happened" test "$(n_events 'label 77 add blocked')" = 1
reset; cycle   # the owner unblocked: the card is eligible again, nothing was spent since
t "AC-3 an unblocked card starts again (its allowance counts from the unblock, not from the start)" launched_has "/sf:develop 77"
t "AC-3 and is not blocked a second time at once" test "$(n_events 'label 77 add blocked')" = 0
tx s4 77 develop 39 today; reset; cycle   # 80 in all, 39 since the unblock
t "AC-3 39 since the unblock is under card_block: it still starts" launched_has "/sf:develop 77"
t "AC-3 and nothing is posted" test "$(n_events 'comment 77')" = 0
tx s5 77 develop 2 today; reset; cycle    # 82 in all, 41 since the unblock
t "AC-3 41 since the unblock reaches card_block: not started" not launched_has "/sf:develop 77"
t "AC-3 blocked once more" test "$(n_events 'label 77 add blocked')" = 1
t "AC-3 with a new comment" test -e "$tmp/comment-77-2"
t "AC-3 the new marker's baseline is the previous total (41)" near "$(jget "$m" 'd["baseline"]')" 41
t "AC-3 the new marker keeps the card's whole total (82)" near "$(jget "$m" 'd["total"]')" 82
t "AC-3 the new marker's stages are the spend of the counted span (41)" near "$(jget "$m" 'sum(d["stages"].values())')" 41

# ---- AC-4: the day stop
setup; machine $'costs:\n  day_stop: 80'
tx s1 11 develop 50 today; tx s2 12 develop 31 today "" other
live_lock develop-5 5
Q_DEV="90"; Q_REF="92"; Q_VAL="91"; Q_PROD="93"; cycle
t "AC-4 the cycle exits 0" test "$RC" = 0
t "AC-4 no develop run starts when today's estimate (81, across projects) passed day_stop (80)" not launched_has "/sf:develop 90"
t "AC-4 no refine run starts" not launched_has "/sf:refine 92"
t "AC-4 no validate run starts" not launched_has "/sf:validate 91"
t "AC-4 no deploy run starts" not launched_has "deploy 93"
t "AC-4 the dispatcher says why" grep -qF "reached costs.day_stop" <<< "$OUT"
t "AC-4 the log line gives the estimate" grep -qE "today's estimate US\\$ 81" <<< "$OUT"
t "AC-4 the log line gives the limit" grep -qE "costs\\.day_stop \\(US\\$ 80" <<< "$OUT"
t "AC-4 the log line says no run until tomorrow" grep -qF "no new run until tomorrow" <<< "$OUT"
t "AC-4 a running session is left alone" test -d "$FACTORY_HOME/locks/develop-5.lock"
t "AC-4 the limits CLI prints day_stop<TAB>today<TAB>limit" test "$(day_field 1)" = day_stop
t "AC-4 ... with today's estimate across all projects" near "$(day_field 2)" 81
t "AC-4 ... and the limit" near "$(day_field 3)" 80
t "AC-4 no card is blocked by the day stop" test "$(n_events 'label [0-9]* add blocked')" = 0
# the limit acts at >= too
setup; machine $'costs:\n  day_stop: 80'; tx s1 11 develop 50 today; tx s2 12 develop 30 today "" other; Q_DEV="90"; cycle
t "AC-4 today's estimate exactly at day_stop stops the day" not launched_has "/sf:develop 90"
# under the limit: the day runs
setup; machine $'costs:\n  day_stop: 80'; tx s1 11 develop 50 today; tx s2 12 develop 29 today "" other; Q_DEV="90"; cycle
t "AC-4 79 is under day_stop: runs start" launched_has "/sf:develop 90"
t "AC-4 ... and the limits CLI prints no day_stop" test -z "$(day_field 1)"

# ---- AC-5: the local day changes and runs start again, with nothing for the owner to do
setup; machine $'costs:\n  day_stop: 80'; tx s1 11 develop 50 today; tx s2 12 develop 31 today "" other; Q_DEV="90"; cycle
t "AC-5 stopped while the estimate is today's" not launched_has "/sf:develop 90"
# the same sessions, one day later: they now belong to yesterday
tx s1 11 develop 50 yesterday; tx s2 12 develop 31 yesterday "" other
touch -d '2 minutes ago' "$CLAUDE_CONFIG_DIR"/projects/*/s1.jsonl "$CLAUDE_CONFIG_DIR"/projects/*/s2.jsonl
reset; cycle
t "AC-5 the next cycle starts the run again" launched_has "/sf:develop 90"
t "AC-5 no day_stop line any more" test -z "$(day_field 1)"
t "AC-5 the dispatcher no longer says the day is stopped" not grep -qF "reached costs.day_stop" <<< "$OUT"

# ---- AC-6: a card that ran on a model with no price is never judged, and adds nothing to the day
setup; machine $'costs:\n  card_warn: 50\n  card_block: 60\n  day_stop: 5'
tx u1 80 develop 100 today claude-mystery-1          # unpriced only: the estimate is unknown
tx p1 81 develop 3 today                              # priced, small
tx p2 82 develop 70 yesterday; tx u2 82 refine 100 today claude-mystery-1   # over card_block in dollars, but one stage is unpriced
Q_DEV="80 81 82"; cycle
t "AC-6 an unpriced card is not blocked" launched_has "/sf:develop 80"
t "AC-6 a card with one unpriced session has an unknown estimate, so it is not blocked" launched_has "/sf:develop 82"
t "AC-6 a priced card still starts" launched_has "/sf:develop 81"
t "AC-6 unpriced runs add nothing to the day: 3 is under day_stop 5" test -z "$(day_field 1)"
t "AC-6 nothing is labeled" test "$(n_events 'label [0-9]* add blocked')" = 0
t "AC-6 nothing is commented" test ! -e "$tmp/comment-80-1" -a ! -e "$tmp/comment-82-1"
t "AC-6 no marker for a card with an unknown estimate" test ! -e "$FACTORY_HOME/cost/80.json" -a ! -e "$FACTORY_HOME/cost/82.json"
t "AC-6 the limits CLI lists no card" test -z "$(lim)"

# ---- AC-7: no costs, or only some of the three keys: each absent limit does nothing
# base [nobig]: cards 78-80 spent 30 today each (90, and 120 with another project's 30); card 77 spent 500 days ago
base() {
  setup; tx b 78 develop 30 today; tx c 79 develop 30 today; tx d 80 develop 30 today; tx e 5 develop 30 today "" other; Q_DEV="78 79 80"
  [ "${1:-}" = nobig ] || { tx a 77 develop 500 yesterday; Q_DEV="77 78 79 80"; }
}
all_started() { local n; for n in $Q_DEV; do launched_has "/sf:develop $n" || return 1; done; }
nothing_done() { [ ! -s "$tmp/events" ] && [ ! -e "$FACTORY_HOME/cost" -o -z "$(ls "$FACTORY_HOME/cost" 2>/dev/null)" ]; }
base; cycle
t "AC-7 no costs: every card starts, whatever it spent" all_started
t "AC-7 no costs: no label, no comment, no marker" nothing_done
t "AC-7 no costs: the estimate is not even started (no cost-cache.json)" test ! -e "$SHIPFLOOR_HOME/cost-cache.json"
t "AC-7 no costs: the limits CLI prints nothing" test -z "$(lim)"
base; machine $'costs:\n  card_warn: 20'; cycle
t "AC-7 only card_warn: nothing blocks, nothing stops the day" all_started
t "AC-7 only card_warn: no label, no comment" nothing_done
base nobig; machine $'costs:\n  card_block: 40'; cycle
t "AC-7 only card_block: 120 spent today across projects does not stop the day (no day_stop)" all_started
t "AC-7 only card_block: the cards under it are untouched" nothing_done
base; machine $'costs:\n  day_stop: 200'; cycle
t "AC-7 only day_stop: a card that spent 500 is not blocked (no card_block)" all_started
t "AC-7 only day_stop: no label, no comment" nothing_done
base; machine $'costs:\n  card_warn: 20\n  day_stop: 200'; cycle
t "AC-7 card_warn and day_stop without card_block: nothing blocks" all_started
finish
