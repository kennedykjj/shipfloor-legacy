#!/usr/bin/env bash
# #168 AC-3: what a run's agent gets, exactly: its flags in order, the prompt "/sf:<p> <n>" on stdin with no newline, its
# cwd (the control checkout, PWD too), its environment (set, passed and removed variables), and the == start / == end
# lines of logs/<date>-<n>-<stage>.log. The deploy script gets the same environment and cwd.
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
BASE_CONFIG="$FACTORY_CONFIG"
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}'

fresh() {  # fresh: a new home; the run and the deploy script write down their argv, stdin, cwd and environment
  T="$(mktemp -d)"; export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_PROJECT=shop
  export Q_DEV= Q_PROD=
  mkdir -p "$FACTORY_HOME/control"
  printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Ready for Prod") echo "${Q_PROD:-}" ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
c="$T/claude.$(ls "$T" | grep -c '^claude\.[0-9]*\.argv$')"
printf '%s\n' "$@" > "$c.argv"; cat > "$c.stdin"; pwd -P > "$c.cwd"; echo "$PWD" > "$c.pwd"; env > "$c.env"
echo "claude says hi"
EOC
  cat > "$T/deploy" <<'EOD'
#!/usr/bin/env bash
c="$T/deploy.$(ls "$T" | grep -c '^deploy\.[0-9]*\.argv$')"
printf '%s\n' "$@" > "$c.argv"; pwd -P > "$c.cwd"; env > "$c.env"
[ "${2:-}" = --continue ] && exit 0
exit 3
EOD
  chmod +x "$T/board" "$T/claude" "$T/deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude" FACTORY_DEPLOY="$T/deploy"
}
envof() { grep "^$2=" "$T/$1.env" | head -n 1 | cut -d= -f2-; }
hasenv() { grep -q "^$2=" "$T/$1.env"; }

# ---- a develop run: argv, stdin, cwd, environment, log lines
fresh; export Q_DEV=54 CALLER_VAR="kept as is" FACTORY_BOARD_SNAPSHOT=/caller/snapshot
run_dispatch >/dev/null 2>&1
unset CALLER_VAR FACTORY_BOARD_SNAPSHOT
plugin="$(cd "$FACTORY_DIR/.." && pwd)"; [ ! -f "$FACTORY_DIR/.source" ] || plugin="$(cat "$FACTORY_DIR/.source")"
want="$(printf '%s\n' -p --permission-mode acceptEdits --add-dir "$FACTORY_WT_ROOT" --add-dir "$FACTORY_HOME/tmp" \
  --add-dir "$FACTORY_HOME/reviews" --setting-sources project,local --strict-mcp-config --plugin-dir "$plugin" \
  --allowedTools "Read(/$(cd "$FACTORY_DIR" && pwd)/**)" --disallowedTools PowerShell --append-system-prompt \
  "This is an unattended factory run. A personal CLAUDE.md is for its owner's interactive sessions: what it says to read or write under ~/.claude (memory, journals, notes, a vault) does not apply here." \
  --model sonnet)"
t "AC-3 the agent's argv is exactly today's, flag for flag and in order" test "$(cat "$T/claude.0.argv")" = "$want"
[ "$(cat "$T/claude.0.argv")" = "$want" ] || diff <(echo "$want") "$T/claude.0.argv" | sed 's/^/    /'
t "AC-3 stdin is the prompt '/sf:develop 54' with no newline" cmp -s "$T/claude.0.stdin" <(printf '/sf:develop 54')
t "AC-3 the agent runs in the control checkout" test "$(cat "$T/claude.0.cwd")" = "$(cd "$FACTORY_HOME/control" && pwd -P)"
t "AC-3 ... and PWD names it" test "$(cat "$T/claude.0.pwd")" = "$FACTORY_HOME/control"
t "AC-3 SHIPFLOOR_FACTORY=1" test "$(envof claude.0 SHIPFLOOR_FACTORY)" = 1
t "AC-3 SHIPFLOOR_RUN_LOCK is the run's lock" test "$(envof claude.0 SHIPFLOOR_RUN_LOCK)" = "$FACTORY_HOME/locks/develop-54.lock"
t "AC-3 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0" test "$(envof claude.0 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS)" = 0
t "AC-3 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" test "$(envof claude.0 CLAUDE_CODE_DISABLE_AUTO_MEMORY)" = 1
t "AC-3 FACTORY_LANGUAGE is the project's language" test "$(envof claude.0 FACTORY_LANGUAGE)" = en
t "AC-3 FACTORY_HOME, FACTORY_WT_ROOT and SHIPFLOOR_HOME are exported" test "$(envof claude.0 FACTORY_HOME)|$(envof claude.0 FACTORY_WT_ROOT)|$(envof claude.0 SHIPFLOOR_HOME)" = "$FACTORY_HOME|$FACTORY_WT_ROOT|$SHIPFLOOR_HOME"
t "AC-3 FACTORY_CONFIG and FACTORY_PROJECT pass through" test "$(envof claude.0 FACTORY_CONFIG)|$(envof claude.0 FACTORY_PROJECT)" = "$FACTORY_CONFIG|shop"
t "AC-3 a variable of the caller passes through unchanged" test "$(envof claude.0 CALLER_VAR)" = "kept as is"
t "AC-3 FACTORY_BOARD_SNAPSHOT is removed (a run reads the live board)" not hasenv claude.0 FACTORY_BOARD_SNAPSHOT
t "AC-3 no SHIPFLOOR_INFRA_RETRY without an infra marker" not hasenv claude.0 SHIPFLOOR_INFRA_RETRY
log="$FACTORY_HOME/logs/$(date +%F)-54-develop.log"
t "AC-3 the log is logs/<date>-<n>-<stage>.log" test -f "$log"
t "AC-3 the first line is '== start /sf:develop 54 <date -Is> pid=<n> model=sonnet weight=standard'" grep -Eq "^== start /sf:develop 54 $ISO pid=[0-9]+ model=sonnet weight=standard\$" <<< "$(head -n 1 "$log")"
t "AC-3 what the agent prints follows" test "$(sed -n 2p "$log")" = "claude says hi"
t "AC-3 the last line is '== end /sf:develop 54 exit=0 <date -Is>'" grep -Eq "^== end /sf:develop 54 exit=0 $ISO\$" <<< "$(tail -n 1 "$log")"
t "AC-3 three lines in all" test "$(grep -c '' "$log")" = 3

# ---- a deploy run: the script, then one agent round on exit 3
fresh; export Q_PROD=47
run_dispatch >/dev/null 2>&1
t "AC-3 deploy.sh is called with the card" test "$(cat "$T/deploy.0.argv")" = 47
t "AC-3 ... then with --continue after the agent's round" test "$(cat "$T/deploy.1.argv")" = "$(printf '47\n--continue')"
t "AC-3 the round's agent gets '/sf:deploy 47'" cmp -s "$T/claude.0.stdin" <(printf '/sf:deploy 47')
t "AC-3 deploy.sh runs in the control checkout" test "$(cat "$T/deploy.0.cwd")" = "$(cd "$FACTORY_HOME/control" && pwd -P)"
t "AC-3 deploy.sh gets SHIPFLOOR_FACTORY=1 and the run's lock" test "$(envof deploy.0 SHIPFLOOR_FACTORY)|$(envof deploy.0 SHIPFLOOR_RUN_LOCK)" = "1|$FACTORY_HOME/locks/deploy-47.lock"
t "AC-3 deploy.sh gets no FACTORY_BOARD_SNAPSHOT" not hasenv deploy.0 FACTORY_BOARD_SNAPSHOT
log="$FACTORY_HOME/logs/$(date +%F)-47-deploy.log"
t "AC-3 the deploy run's start line has its model and weight" grep -Eq "^== start /sf:deploy 47 $ISO pid=[0-9]+ model=sonnet weight=standard\$" <<< "$(head -n 1 "$log")"
t "AC-3 the deploy run ends with the script's last exit code" grep -Eq "^== end /sf:deploy 47 exit=0 $ISO\$" <<< "$(tail -n 1 "$log")"

# ---- no control checkout: the run's one line says so
fresh; export Q_DEV=26; rm -rf "$FACTORY_HOME/control"
run_dispatch >/dev/null 2>&1
t "AC-3 without a control checkout the log ends '== end /sf:develop 26 exit=1 <date -Is>: no <control>'" grep -Eq "^== end /sf:develop 26 exit=1 $ISO: no $FACTORY_HOME/control\$" <<< "$(tail -n 1 "$FACTORY_HOME/logs/$(date +%F)-26-develop.log")"
t "AC-3 ... and no agent ran" test ! -e "$T/claude.0.argv"
finish
