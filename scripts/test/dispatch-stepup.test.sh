#!/usr/bin/env bash
# #133 AC-4, AC-5: a develop run below the top model that ends on a failed gate runs once more, one model up, from
# the dispatcher's next cycle; the run's log and the dispatcher's line name both models and the gate. A run that
# already stepped up, ran on the top model or a model off the ladder, or ended any other way fails as it does today.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"
tmp="$(mktemp -d)"
# the board: card 54 waits in Ready for Dev (FIRST) or sits in Coding as an orphan (ORPHAN); every label call is logged
cat > "$tmp/board" <<'B'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Dev") if [ -e "$T/first" ]; then echo 54; fi ;;
  "eligible Coding") if [ -e "$T/orphan" ]; then echo 54; fi ;;
  "snapshot ") printf '54\t%s\tI_1\n' "$(cat "$T/column" 2>/dev/null || echo Coding)" ;;
  "label 54") echo "$*" >> "$T/labels" ;;
  *) echo ;;
esac
B
# the run: its gate's verdict goes to the run's lock as gate.sh writes it; VERDICT empty = no gate ran
cat > "$tmp/claude" <<'C'
#!/usr/bin/env bash
cat >/dev/null; echo "args=$*"
[ -n "${VERDICT:-}" ] && printf '%s\t%s\n' "${GATE_NAME:-build}" "$VERDICT" > "$SHIPFLOOR_RUN_LOCK/last-gate"
exit "${EXIT:-0}"
C
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude" T="$tmp"

fresh() {  # fresh [config.yml]: a new factory home, card 54 in Ready for Dev
  export FACTORY_HOME="$(mktemp -d)" SHIPFLOOR_HOME="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "$SHIPFLOOR_HOME/config.yml"
  rm -f "$tmp/labels" "$tmp/orphan" "$tmp/column"; touch "$tmp/first"
}
cycle() {  # one dispatcher cycle; LOG = card 54's develop log, OUT = what the dispatcher said
  run_dispatch > "$tmp/out" 2>&1; RC=$?
  LOG="$(cat "$FACTORY_HOME"/logs/*-54-develop.log 2>/dev/null)"; OUT="$(cat "$tmp/out")"
}
as_orphan() { rm -f "$tmp/first"; touch "$tmp/orphan"; }  # what the board shows once the block came off
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3: no '$2' in: ${1:0:400}" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3: found '$2' in: ${1:0:400}" ;; *) pass "$3" ;; esac; }
starts() { grep -c '^== start /sf:develop 54' <<< "$LOG"; }
labels() { cat "$tmp/labels" 2>/dev/null; }

# AC-4: sonnet fails a gate -> the block comes off, the marker says sonnet -> opus, and the next cycle runs on opus
AC="AC-4"
fresh
VERDICT=FAIL GATE_NAME=build cycle
has "$LOG" "model=sonnet" "AC-4 the first develop run started on sonnet"
has "$LOG" "== step-up /sf:develop 54 sonnet -> opus: gate build failed" "AC-4 the run's log names both models and the gate"
[ "$(cat "$FACTORY_HOME/stepup/54" 2>/dev/null)" = $'sonnet\topus\tbuild' ] && pass "AC-4 the step-up marker holds from, to and the gate" || fail "AC-4 stepup/54 is '$(cat "$FACTORY_HOME/stepup/54" 2>/dev/null)'"
[ "$(labels)" = "label 54 remove blocked" ] && pass "AC-4 the blocked label comes off so the card resumes" || fail "AC-4 label calls: '$(labels)'"
has "$OUT" "dispatch: #54 failed gate build on sonnet; the next run is on opus" "AC-4 the dispatcher's line names both models"
as_orphan
VERDICT=FAIL GATE_NAME=green cycle
[ "$(starts)" = 2 ] && pass "AC-4 the next cycle started one more develop run" || fail "AC-4 $(starts) develop starts in the log, want 2"
has "$(grep '^== start' <<< "$LOG" | tail -1)" "model=opus" "AC-4 the second run starts on opus"
has "$(grep -A1 '^== start' <<< "$LOG" | tail -1)" "--model opus" "AC-4 its command carries --model opus"
has "$OUT" "dispatch: #54 runs on opus, one model up after sonnet failed gate build" "AC-4 the dispatcher says why the model changed"

# AC-5: the run that already stepped up fails too: no third run, no new marker, the card stays blocked
AC="AC-5"
[ "$(grep -c '^== step-up' <<< "$LOG")" = 1 ] && pass "AC-5 a stepped-up run that fails steps up no further" || fail "AC-5 $(grep -c '^== step-up' <<< "$LOG") step-up lines, want 1"
[ "$(labels | grep -c .)" = 1 ] && pass "AC-5 its block stays on" || fail "AC-5 label calls: '$(labels)'"
[ "$(cut -f2 "$FACTORY_HOME/stepup/54")" = opus ] && pass "AC-5 the marker keeps opus while the card is in Coding" || fail "AC-5 stepup/54: '$(cat "$FACTORY_HOME/stepup/54")'"
# an unblocked card keeps the higher model and never steps again
VERDICT=FAIL cycle
has "$(grep '^== start' <<< "$LOG" | tail -1)" "model=opus" "AC-5 a card unblocked by hand keeps the higher model"
# the marker goes once the card leaves Coding
rm -f "$tmp/orphan"; echo Validation > "$tmp/column"; cycle
[ ! -e "$FACTORY_HOME/stepup/54" ] && pass "AC-5 the marker goes when the card leaves Coding" || fail "AC-5 stepup/54 outlived Coding"

# a heavy card runs on opus, the top model: a failed gate is handled as today
card() { local wt="$FACTORY_WT_ROOT/54"; rm -rf "$wt"; cp -r "$(new_repo)" "$wt"; git -C "$wt" checkout -q -b feat/54-thing
  mkdir -p "$wt/docs/superpowers/specs"; printf '# x\n\n**Weight:** %s\n\n## Product\n' "$1" > "$wt/docs/superpowers/specs/2026-10-12-thing-design.md"; }
card heavy; fresh
VERDICT=FAIL cycle
has "$LOG" "model=opus" "AC-5 a heavy card's run is on opus"
lacks "$LOG" "== step-up" "AC-5 the top model never steps up"
[ ! -e "$FACTORY_HOME/stepup/54" ] && [ -z "$(labels)" ] && pass "AC-5 no marker, no label change on the top model" || fail "AC-5 top model: marker or labels: '$(labels)'"
rm -rf "${FACTORY_WT_ROOT:?}/54"
# a model off the ladder (fable), an infrastructure verdict, a pass, no gate, a run that did not exit 0
fresh $'models:\n  stages: {develop: fable}'; VERDICT=FAIL cycle
lacks "$LOG" "== step-up" "AC-5 a model off the ladder never steps up"
fresh; VERDICT=INFRA cycle
lacks "$LOG" "== step-up" "AC-5 INFRA belongs to the infra retry, not the step-up"
fresh; VERDICT=pass cycle
lacks "$LOG" "== step-up" "AC-5 a run whose last gate passed does not step up"
fresh; VERDICT="" cycle
lacks "$LOG" "== step-up" "AC-5 a run with no gate verdict does not step up"
fresh; VERDICT=FAIL EXIT=1 cycle
lacks "$LOG" "== step-up" "AC-5 a run that did not end cleanly does not step up"
[ ! -d "$FACTORY_HOME/stepup" ] || [ -z "$(ls "$FACTORY_HOME/stepup")" ] && pass "AC-5 none of these wrote a marker" || fail "AC-5 a marker was written: $(ls "$FACTORY_HOME/stepup")"
# haiku steps to sonnet
fresh $'models:\n  stages: {develop: haiku}'; VERDICT=FAIL cycle
has "$LOG" "== step-up /sf:develop 54 haiku -> sonnet: gate build failed" "AC-4 haiku steps up to sonnet"
finish
