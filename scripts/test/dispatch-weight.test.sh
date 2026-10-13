#!/usr/bin/env bash
# #133 AC-2, AC-3: a run's model comes from the card's weight (its spec header) and the stage's model for it.
# With the shipped table a light or standard card's develop session starts on sonnet, a heavy one on opus; a spec
# refined before weights existed runs as standard and is never refused.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0
tmp="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Dev") echo 54 ;; "eligible Validation") echo 60 ;; *) echo ;; esac\n' > "$tmp/board"
printf '#!/usr/bin/env bash\necho "prompt=$(cat) args=$*"\nexit 3\n' > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"

card() {  # card <n> <header line, or "" for none, or "-" for no spec>: card <n>'s worktree on feat/<n>-thing
  local wt="$FACTORY_WT_ROOT/$1"; rm -rf "$wt"; cp -r "$(new_repo)" "$wt"
  git -C "$wt" checkout -q -b "feat/$1-thing"
  [ "$2" = - ] && return 0
  mkdir -p "$wt/docs/superpowers/specs"
  printf '# Thing — spec\n\n**Issue:** #%s\n**Roles:** PO, Tech Lead\n%s\n\n## Product\n- **AC-1** — x\n\n## Decisions\n- **Weight:** heavy\n' "$1" "$2" > "$wt/docs/superpowers/specs/2026-10-12-thing-design.md"
}
cycle() {  # cycle <config.yml text, or empty>: one dispatcher cycle on a fresh home; the cards' worktrees stay
  export FACTORY_HOME="$(mktemp -d)" SHIPFLOOR_HOME="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  [ -z "$1" ] || printf '%s\n' "$1" > "$SHIPFLOOR_HOME/config.yml"
  run_dispatch; RC=$?
  DEV="$(cat "$FACTORY_HOME"/logs/*-54-develop.log 2>/dev/null)"; VAL="$(cat "$FACTORY_HOME"/logs/*-60-validate.log 2>/dev/null)"
}
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3: no '$2' in the run's log: ${1:0:300}" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3: found '$2' in the run's log: ${1:0:300}" ;; *) pass "$3" ;; esac; }
export FACTORY_WT_ROOT="$(mktemp -d)"

# AC-2: the shipped table
card 54 "**Weight:** light"; card 60 "**Weight:** heavy"
cycle ""
has "$DEV" "--model sonnet" "AC-2 a light card's develop session starts with --model sonnet"
has "$DEV" "model=sonnet weight=light" "AC-2 the start line names the model and the weight"
has "$VAL" "--model sonnet" "AC-2 validate runs a heavy card on sonnet by default"
card 54 "**Weight:** heavy"
cycle ""
has "$DEV" "--model opus" "AC-2 a heavy card's develop session starts with --model opus"
lacks "$DEV" "--model sonnet" "AC-2 and not on sonnet"
has "$DEV" "model=opus weight=heavy" "AC-2 the start line names opus and heavy"
card 54 "**Weight:** standard"
cycle ""
has "$DEV" "--model sonnet" "AC-2 a standard card's develop session starts with --model sonnet"
# the table is the machine's: a weight set there wins, the others keep theirs
card 54 "**Weight:** light"; card 60 "**Weight:** heavy"
cycle $'models:\n  stages:\n    develop: {light: haiku}\n    validate: {heavy: opus}'
has "$DEV" "--model haiku" "AC-2 models.stages.develop.light: haiku puts a light card on haiku"
has "$VAL" "--model opus" "AC-2 models.stages.validate.heavy: opus puts a heavy card's validation on opus"
card 54 "**Weight:** heavy"
cycle $'models:\n  stages:\n    develop: {light: haiku}'
has "$DEV" "--model opus" "AC-2 a heavy card keeps the default heavy model when only light is set"

# AC-3: no weight line, another value, two lines, no spec, no worktree: standard, and the run starts
for header in "" "**Weight:** medium" $'**Weight:** light\n**Weight:** heavy'; do
  card 54 "$header"
  cycle $'models:\n  stages:\n    develop: {light: haiku, standard: sonnet, heavy: opus}'
  [ "$RC" = 0 ] && pass "AC-3 the dispatcher exits 0 ('${header//$'\n'/ / }')" || fail "AC-3 the dispatcher exited $RC ('$header')"
  has "$DEV" "== start /sf:develop 54" "AC-3 the develop run started ('${header//$'\n'/ / }')"
  has "$DEV" "--model sonnet" "AC-3 it runs as standard ('${header//$'\n'/ / }')"
  has "$DEV" "weight=standard" "AC-3 the start line says standard ('${header//$'\n'/ / }')"
done
card 54 -
cycle ""
has "$DEV" "weight=standard" "AC-3 a worktree with no spec runs as standard"
rm -rf "${FACTORY_WT_ROOT:?}/54"
cycle ""
has "$DEV" "== start /sf:develop 54" "AC-3 a card with no worktree yet still starts"
has "$DEV" "--model sonnet" "AC-3 and runs as standard"
finish
