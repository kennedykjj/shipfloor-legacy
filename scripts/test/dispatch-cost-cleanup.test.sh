#!/usr/bin/env bash
# #160 AC-3 (and AC-8): the order of a dispatch and what it cleans, pinned as it is today.
#  - day_stop exits before the infra retry runs
#  - cost/*.json and stepup/* go when their card leaves the board, and never when board.tsv is empty
#  - block_card with python rc 2: the marker is restored from .prev, the card is not started, the cycle fails
#  - AC-8: the suite has a test file for every issue group, and the dispatcher scripts are as committed
# Transcripts and prices are fake files under temp dirs: nothing here reads the real ~/.claude or ~/.shipfloor.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
REALPY="$FACTORY_PYTHON"; BASE_CONFIG="$FACTORY_CONFIG"
[ "$(date +%H%M)" -ge 2358 ] && sleep 150   # "today" is the machine's local date: do not straddle midnight

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }

setup() {  # setup [machine config text]: a new home for project shop, a fake board / claude / gh / deploy, nothing queued
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_PYTHON="$REALPY" FACTORY_CONFIG="$BASE_CONFIG"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export CLAUDE_CONFIG_DIR="$(nat "$(mktemp -d)")"
  unset SHIPFLOOR_MAX_PARALLEL
  export Q_DEV= Q_INFRA=
  T="$(mktemp -d)"; export T
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  printf 'claude-opus-5-5: {input: 4.00, output: 20.00, cache_write_5m: 5.00, cache_write_1h: 8.00, cache_read: 0.20}\n' > "$SHIPFLOOR_HOME/prices.yml"
  { printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n'; [ -z "${1:-}" ] || printf '%s\n' "$1"; } > "$SHIPFLOOR_HOME/config.yml"
  # the board: every call is logged; the snapshot is whatever $T/snapshot holds
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
echo "$*" >> "$T/board.calls"
case "$1 ${2:-}" in
  "snapshot ") if [ -f "$T/snapshot" ]; then cat "$T/snapshot"; fi ;;
  "infra ") echo "${Q_INFRA:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible "*|"label "*) ;;
  *) echo 0 ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat)" >> "$T/launched"\n' > "$T/claude"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "$T/gh.calls"\nexit 0\n' > "$T/gh"
  chmod +x "$T/board" "$T/claude" "$T/gh"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude" FACTORY_GH="$T/gh"
  : > "$T/launched"; : > "$T/board.calls"
}
tx() {  # tx <name> <issue> <US$>: today's transcript of one develop session of project shop, costing US$ at $4 per million input tokens
  local d="$CLAUDE_CONFIG_DIR/projects/C--x--shipfloor-projects-shop-control" day; mkdir -p "$d"; day="$(date +%F)"
  { printf '{"type":"user","timestamp":"%sT12:00:00%s","message":{"role":"user","content":"<command-name>/sf:develop</command-name>\\n<command-args>%s</command-args>"}}\n' "$day" "$(date +%:z)" "$2"
    printf '{"type":"assistant","timestamp":"%sT12:05:00%s","message":{"id":"m-%s","model":"claude-opus-5-5","usage":{"input_tokens":%s,"output_tokens":0}}}\n' "$day" "$(date +%:z)" "$1" "$(( $3 * 250000 ))"
  } > "$d/$1.jsonl"
}
cycle() { OUT="$(run_dispatch 2>&1; echo "rc=$?")"; RC="${OUT##*rc=}"; }
launched_has() { grep -qF -- "$1" "$T/launched"; }
called() { grep -q -- "$1" "$T/board.calls"; }

# ---- AC-3: day_stop exits before the infra retry runs
setup $'costs:\n  day_stop: 80'; tx s1 11 81; Q_DEV=90; Q_INFRA=54; export Q_DEV Q_INFRA
cycle
t "AC-3 a day past day_stop: the dispatch exits 0" test "$RC" = 0
t "AC-3 the dispatcher says why (the day is stopped)" grep -qF "reached costs.day_stop" <<< "$OUT"
t "AC-3 no run starts" test ! -s "$T/launched"
t "AC-3 the board is read once (the snapshot) and nothing after it: no infra query" not called '^infra'
t "AC-3 no queue is asked for either" not called '^eligible'
t "AC-3 the infra retry did not run: no infra/54 marker" test ! -e "$FACTORY_HOME/infra/54"
t "AC-3 the infra retry did not run: no label call" not called '^label'
t "AC-3 the snapshot was read before the exit" called '^snapshot'
# the same cycle under the limit does run the infra retry first
setup $'costs:\n  day_stop: 80'; tx s1 11 79; Q_DEV=90; Q_INFRA=54; export Q_DEV Q_INFRA
cycle
t "AC-3 contrast: under day_stop the infra retry runs (infra/54 written)" test -f "$FACTORY_HOME/infra/54"
t "AC-3 contrast: ... and the infra query was made" called '^infra'
t "AC-3 contrast: ... and a run starts" launched_has "/sf:develop 90"

# ---- AC-3: cost/*.json and stepup/* go when the card leaves the board
markers() {  # markers: cost markers for cards 54 (on the board), 55 (gone), 56 (Validation); step-up markers for 54 (Coding), 56 (Validation), 57 (gone), 58 (gone, but a run holds it)
  mkdir -p "$FACTORY_HOME/cost" "$FACTORY_HOME/stepup" "$FACTORY_HOME/locks/develop-58.lock"
  for n in 54 55 56; do echo '{"total": 1}' > "$FACTORY_HOME/cost/$n.json"; done
  for n in 54 56 57 58; do printf 'sonnet\topus\tbuild\n' > "$FACTORY_HOME/stepup/$n"; done
  echo "$$ $(date +%s) 58" > "$FACTORY_HOME/locks/develop-58.lock/info"
}
setup; markers
printf '54\tCoding\tI_54\n56\tValidation\tI_56\n' > "$T/snapshot"
cycle
t "AC-3 the dispatch with a board read succeeds" test "$RC" = 0
t "AC-3 cost/55.json goes: card 55 left the board" test ! -e "$FACTORY_HOME/cost/55.json"
t "AC-3 cost/54.json stays: its card is on the board" test -f "$FACTORY_HOME/cost/54.json"
t "AC-3 cost/56.json stays: any column counts as on the board" test -f "$FACTORY_HOME/cost/56.json"
t "AC-3 stepup/57 goes: card 57 left the board" test ! -e "$FACTORY_HOME/stepup/57"
t "AC-3 stepup/56 goes: its card is no longer in Coding" test ! -e "$FACTORY_HOME/stepup/56"
t "AC-3 stepup/54 stays: its card is in Coding" test -f "$FACTORY_HOME/stepup/54"
t "AC-3 stepup/58 stays: a live run holds the card" test -f "$FACTORY_HOME/stepup/58"
# an empty board.tsv proves nothing: nothing is removed
setup; markers; : > "$T/snapshot"
cycle
t "AC-3 an empty board read: the dispatch still succeeds" test "$RC" = 0
t "AC-3 an empty board.tsv removes no cost marker (55 stays)" test -f "$FACTORY_HOME/cost/55.json"
t "AC-3 ... nor the others (54, 56)" test -f "$FACTORY_HOME/cost/54.json" -a -f "$FACTORY_HOME/cost/56.json"
t "AC-3 an empty board.tsv removes no step-up marker (57 stays)" test -f "$FACTORY_HOME/stepup/57"
t "AC-3 ... nor 56, which is outside Coding" test -f "$FACTORY_HOME/stepup/56"
t "AC-3 the board.tsv written is empty" test ! -s "$FACTORY_HOME/board.tsv"
setup; markers; printf '\n' > "$T/snapshot"
cycle
t "AC-3 a board.tsv with only a blank line is empty too: cost/55.json stays" test -f "$FACTORY_HOME/cost/55.json"
t "AC-3 ... and stepup/57 stays" test -f "$FACTORY_HOME/stepup/57"

# ---- AC-3: block_card with python rc 2: restore from .prev, no start
# the cost CLI answers through a wrapper of python: `limits` names card 77 as over card_block, `block` exits 2 (after
# touching the marker, as a CLI that died half way would); every other python call is the real one
rc2() {  # rc2 <marker content or "-" for none> <mutate 0|1>: one dispatch with cards 77 (over the limit) and 78 queued
  setup $'costs:\n  card_block: 40'
  cat > "$T/pywrap" <<'EOW'
#!/usr/bin/env bash
if [ "${2##*/}" = dashboard_cost.py ]; then
  case "$3" in
    limits) printf 'block\t77\n'; exit 0 ;;
    block) echo "block $*" >> "$T/py.calls"
           if [ -n "${PY_MUTATE:-}" ]; then mkdir -p "$FACTORY_HOME/cost"; echo mutated > "$FACTORY_HOME/cost/77.json"; fi
           exit 2 ;;
  esac
fi
exec "$REALPY" "$@"
EOW
  chmod +x "$T/pywrap"; export REALPY FACTORY_PYTHON="$T/pywrap"
  mkdir -p "$FACTORY_HOME/cost"; [ "$1" = - ] || printf '%s\n' "$1" > "$FACTORY_HOME/cost/77.json"
  if [ "$2" = 1 ]; then export PY_MUTATE=1; else unset PY_MUTATE; fi
  Q_DEV="77 78"; export Q_DEV
  cycle
  FACTORY_PYTHON="$REALPY"
}
rc2 baseline 1
t "AC-3 python rc 2: the cost CLI was asked to block card 77" grep -q -- '--issue 77' "$T/py.calls"
t "AC-3 python rc 2: the marker is restored from .prev (the original content)" test "$(cat "$FACTORY_HOME/cost/77.json" 2>/dev/null)" = baseline
t "AC-3 python rc 2: no .prev is left behind" test ! -e "$FACTORY_HOME/cost/77.json.prev"
t "AC-3 python rc 2: card 77 is not started" not launched_has "/sf:develop 77"
t "AC-3 python rc 2: the next card in the queue still starts" launched_has "/sf:develop 78"
t "AC-3 python rc 2: the cycle fails (exit 1)" test "$RC" = 1
t "AC-3 python rc 2: the dispatcher says it could not block #77" grep -qF "dispatch: could not block #77 at costs.card_block" <<< "$OUT"
t "AC-3 python rc 2: no comment is posted (gh is not called)" test ! -e "$T/gh.calls"
t "AC-3 python rc 2: no blocked label" not called '^label 77'
rc2 - 1
t "AC-3 python rc 2 with no marker before: the half-written one is removed" test ! -e "$FACTORY_HOME/cost/77.json"
t "AC-3 python rc 2 with no marker before: no .prev either" test ! -e "$FACTORY_HOME/cost/77.json.prev"
t "AC-3 python rc 2 with no marker before: card 77 is not started" not launched_has "/sf:develop 77"
t "AC-3 python rc 2 with no marker before: the cycle fails" test "$RC" = 1
rc2 baseline 0
t "AC-3 python rc 2 that touched nothing: the marker is as it was" test "$(cat "$FACTORY_HOME/cost/77.json" 2>/dev/null)" = baseline
t "AC-3 python rc 2 that touched nothing: no start" not launched_has "/sf:develop 77"

# ---- AC-8: every issue group has its test file in the suite, and the dispatcher scripts are as committed
for f in dispatch-process dispatch-launch-flags dispatch-cost-cleanup dispatch-lang-files shipfloor-dispatch-cycle run-dispatcher; do
  t "AC-8 scripts/test/$f.test.sh exists and asserts something" grep -q 'AC-' "$FACTORY_DIR/test/$f.test.sh"
done
if git -C "$FACTORY_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  t "AC-8 dispatch.sh, shipfloor-dispatch.sh and run-dispatcher.sh are unchanged from the commit" git -C "$FACTORY_DIR" diff --quiet HEAD -- dispatch.sh shipfloor-dispatch.sh run-dispatcher.sh
fi
finish
