#!/usr/bin/env bash
# The model of each stage's run comes from ~/.shipfloor/config.yml (models.stages), read when the run starts (#34).
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"
tmp="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Dev") echo 54 ;; "eligible Validation") echo 60 ;; *) echo ;; esac\n' > "$tmp/board"
printf '#!/usr/bin/env bash\necho "prompt=$(cat) args=$*"\nexit 3\n' > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"

cycle() {  # cycle <config.yml text, or empty for no file>: a fresh home, one dispatcher cycle; the exit code is left in $RC
  export FACTORY_HOME="$(mktemp -d)" SHIPFLOOR_HOME="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  [ -z "$1" ] || printf '%s\n' "$1" > "$SHIPFLOOR_HOME/config.yml"
  run_dispatch; RC=$?
  DEV="$(cat "$FACTORY_HOME"/logs/*-54-develop.log 2>/dev/null)"; VAL="$(cat "$FACTORY_HOME"/logs/*-60-validate.log 2>/dev/null)"
}
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3: no '$2' in the run's command: ${1:0:300}" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3: found '$2' in the run's command: ${1:0:300}" ;; *) pass "$3" ;; esac; }

# AC-1: models.stages.develop: sonnet -> the develop run's command carries --model sonnet
cycle $'models:\n  stages: {develop: sonnet}'
has "$DEV" "== start /sf:develop 54" "AC-1 the develop run started"
has "$DEV" "--model sonnet" "AC-1 models.stages.develop: sonnet puts --model sonnet on the develop run"
has "$VAL" "--model sonnet" "AC-1 validate keeps its sonnet"
cycle $'models:\n  stages: {develop: haiku}'
has "$DEV" "--model haiku" "AC-1 models.stages.develop: haiku puts --model haiku on the develop run"
# a stage's model is its own: validate on opus, develop untouched
cycle $'models:\n  stages: {validate: opus}'
has "$VAL" "--model opus" "AC-1 models.stages.validate: opus puts --model opus on the validate run"
lacks "$VAL" "--model sonnet" "AC-1 validate no longer runs on sonnet"
has "$DEV" "--model sonnet" "AC-1 develop, not configured, keeps its shipped sonnet (a card with no weight is standard)"

# AC-2: nothing configured (or a stage left out) -> today's command lines
cycle ""
has "$DEV" "--model sonnet" "AC-2 no config.yml: develop runs a standard card on sonnet"
has "$VAL" "--model sonnet" "AC-2 no config.yml: validate runs on sonnet"
cycle $'models:\n  stages: {refine: opus}'
lacks "$DEV" "--model opus" "AC-2 refine's model is refine's alone"
has "$DEV" "--model sonnet" "AC-2 a stage left out: develop keeps its shipped sonnet"
has "$VAL" "--model sonnet" "AC-2 a stage left out: validate runs on sonnet"

# AC-5: a model the factory does not know is today's model for that key, and the dispatcher keeps running
cycle $'models:\n  stages: {develop: gpt, validate: gpt}'
[ "$RC" = 0 ] && pass "AC-5 the dispatcher exits 0 on a bad model" || fail "AC-5 the dispatcher exited $RC on a bad model"
has "$DEV" "== start /sf:develop 54" "AC-5 the develop run still started"
has "$DEV" "--model sonnet" "AC-5 develop with an unknown model uses its shipped model"
has "$VAL" "--model sonnet" "AC-5 validate with an unknown model uses today's sonnet"
lacks "$VAL" "gpt" "AC-5 the unknown model never reaches the command"
cycle $'models:\n  stages: {review: opus}\n  agents: {nobody: opus}'
[ "$RC" = 0 ] && pass "AC-5 the dispatcher exits 0 on an unknown stage and agent" || fail "AC-5 the dispatcher exited $RC on an unknown stage and agent"
has "$DEV" "--model sonnet" "AC-5 an unknown stage changes nothing for develop"
finish
