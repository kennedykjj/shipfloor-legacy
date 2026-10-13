#!/usr/bin/env bash
# The pipeline prompt reaches claude unmangled (no MSYS path conversion) and every run is logged.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
tmp="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Dev") echo 54 ;; "eligible Validation") echo 60 ;; *) echo ;; esac\n' > "$tmp/board"
printf '#!/usr/bin/env bash\necho "pathconv=${MSYS_NO_PATHCONV:-unset} prompt=$(cat) bg=$CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS mem=${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-unset} lang=${FACTORY_LANGUAGE:-unset} args=$*"\nexit 3\n' > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
cp "$FACTORY_CONFIG" "$tmp/factory.yml"; export FACTORY_CONFIG="$tmp/factory.yml"  # overrides.yml goes beside it, not in the fixture
run_dispatch
log="$(cat "$FACTORY_HOME"/logs/*-54-develop.log)"
assert_contains "$log" "pathconv=unset prompt=/sf:develop 54 bg=0"
assert_contains "$log" "--setting-sources project,local --strict-mcp-config --plugin-dir "
# a run reads the factory's own folder without being able to write it, has no PowerShell and no personal memory
assert_contains "$log" "--allowedTools Read(/$(cd "$FACTORY_DIR" && pwd)/**)"
assert_contains "$log" "--disallowedTools PowerShell"
assert_contains "$log" "mem=1 "
assert_contains "$log" "--append-system-prompt This is an unattended factory run."
case "$log" in *"reports-wt"*) fail "no rule for a reports folder that does not exist" ;; *) pass "no rule for a missing folder" ;; esac
case "$log" in *"--model"*) fail "develop keeps the default model" ;; esac
assert_contains "$(cat "$FACTORY_HOME"/logs/*-60-validate.log)" "--model sonnet"
assert_contains "$log" "== start /sf:develop 54"
assert_contains "$log" "== end /sf:develop 54 exit=3"
# a run starts with the language the project writes in, read once at launch: it keeps it while it runs (#129)
assert_contains "$log" "mem=1 lang=en "
printf 'language: pt-BR\n' > "$tmp/overrides.yml"
run_dispatch
assert_contains "$(grep -o 'lang=[^ ]*' "$FACTORY_HOME"/logs/*-54-develop.log | tail -n 1)" "lang=pt-BR"
finish
