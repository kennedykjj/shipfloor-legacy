#!/usr/bin/env bash
# #168 (owner's note): each launched run gets its own TMPDIR, a folder inside the card's scratch dir
# ($FACTORY_HOME/tmp/<n>/tmp), created with it before the run starts. Everything the run starts inherits it (the agent,
# and deploy.sh with the agent of its rounds). The folder goes with tmp/<n>/: when the run ends, and by the cycle's sweep
# once the card is Done or off the board. The factory never cleans /tmp itself.
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
BASE_CONFIG="$FACTORY_CONFIG"
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }

fresh() {  # fresh: a new home, a fake board (queues from Q_*, snapshot from BSNAP), a claude and a deploy that report what they see
  T="$(mktemp -d)"; export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_PROJECT=shop
  export Q_DEV= Q_PROD= BSNAP=
  mkdir -p "$FACTORY_HOME/control"
  printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "snapshot ") printf '%b' "${BSNAP:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Ready for Prod") echo "${Q_PROD:-}" ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  # the run: what TMPDIR it got, whether that folder exists, and where its own mktemp lands
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
p="$(cat)"; n="${p##* }"
f="$(mktemp 2>/dev/null)"
{ echo "tmpdir=${TMPDIR:-unset}"; [ -d "${TMPDIR:-/nonexistent}" ] && echo "isdir=yes"; echo "mktemp=$f"; } > "$T/claude-$n.seen"
EOC
  cat > "$T/deploy" <<'EOD'
#!/usr/bin/env bash
echo "tmpdir=${TMPDIR:-unset}" > "$T/deploy-$1.seen"
exit 0
EOD
  chmod +x "$T/board" "$T/claude" "$T/deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude" FACTORY_DEPLOY="$T/deploy"
}
seen() { grep "^$2=" "$T/$1.seen" 2>/dev/null | head -n 1 | cut -d= -f2-; }

# ---- a launched run sees TMPDIR under tmp/<n>/, created before it starts; its own temp files land there
fresh; export Q_DEV="54 55"
run_dispatch >/dev/null 2>&1
t "a develop run sees TMPDIR = \$FACTORY_HOME/tmp/54/tmp" test "$(seen claude-54 tmpdir)" = "$FACTORY_HOME/tmp/54/tmp"
t "... and the folder exists when the run starts" test "$(seen claude-54 isdir)" = yes
case "$(seen claude-54 mktemp)" in "$FACTORY_HOME/tmp/54/tmp/"?*) pass "... a mktemp in the run lands under it" ;; *) fail "... the run's mktemp landed at '$(seen claude-54 mktemp)'" ;; esac
t "each run has its own: card 55 sees \$FACTORY_HOME/tmp/55/tmp" test "$(seen claude-55 tmpdir)" = "$FACTORY_HOME/tmp/55/tmp"
t "the folder goes with the run's tmp/54/ when the run ends" test ! -e "$FACTORY_HOME/tmp/54"
t "... and card 55's too" test ! -e "$FACTORY_HOME/tmp/55"

# ---- a deploy run: deploy.sh inherits it
fresh; export Q_PROD=47
run_dispatch >/dev/null 2>&1
t "deploy.sh of a deploy run sees TMPDIR = \$FACTORY_HOME/tmp/47/tmp" test "$(seen deploy-47 tmpdir)" = "$FACTORY_HOME/tmp/47/tmp"

# ---- the sweep: a run that died left its tmp/<n>/tmp; it goes once the card is Done, and stays while it is in progress
fresh; export BSNAP='54\tDone\tI_54\n56\tCoding\tI_56\n'
mkdir -p "$FACTORY_HOME/tmp/54/tmp/left" "$FACTORY_HOME/tmp/56/tmp/left"
out="$(run_dispatch 2>&1)"
t "a Done card's tmp/54/ goes with the sweep, its TMPDIR folder in it" test ! -e "$FACTORY_HOME/tmp/54"
assert_contains "$out" "dispatch: removed tmp/54"
t "a card still in progress keeps its tmp/56/tmp" test -d "$FACTORY_HOME/tmp/56/tmp/left"

# ---- the cycle leaves the system temp dir alone: its own TMPDIR is not where a run writes
fresh; export Q_DEV=54; mine="$(mktemp -d)"
TMPDIR="$mine" run_dispatch >/dev/null 2>&1
t "a run's TMPDIR is not the cycle's" test "$(seen claude-54 tmpdir)" != "$mine"
t "nothing of the run's is left in the cycle's temp dir" test -z "$(ls -A "$mine")"
finish
