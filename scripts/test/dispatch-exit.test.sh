#!/usr/bin/env bash
# #168 AC-6: how a cycle ends. Exit 2 for an invalid config (project, machine, no project at all), 0 for PAUSE, the
# usage limit, the GitHub limit and day_stop, 1 for a board, cost or step failure. Each line goes to the stream it went
# to before the port (stdout or stderr), with the same text.
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
BASE_CONFIG="$FACTORY_CONFIG"; REALPY="$FACTORY_PYTHON"
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }

fresh() {  # fresh [machine config text]: a new home for project shop; the board answers from Q_* and fails on FAIL_ON
  T="$(mktemp -d)"; export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_PROJECT=shop FACTORY_PYTHON="$REALPY"
  export Q_REF= Q_DEV= FAIL_ON=
  unset FACTORY_REPO
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  { printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n'; [ -z "${1:-}" ] || printf '%s\n' "$1"; } > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
echo "$*" >> "$T/board.calls"
case "$1 ${2:-}" in "$FAIL_ON") echo "board: $1 ${2:-} failed" >&2; exit 1 ;; esac
case "$1 ${2:-}" in
  "eligible Ready for Refinement") echo "${Q_REF:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat)" >> "$T/launched"\n' > "$T/claude"
  chmod +x "$T/board" "$T/claude"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude"
  : > "$T/launched"; : > "$T/board.calls"
}
cycle() { run_dispatch >"$T/out" 2>"$T/err"; RC=$?; OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"; }
in_out() { grep -qF -- "$1" "$T/out"; }
in_err() { grep -qF -- "$1" "$T/err"; }
launched() { test -s "$T/launched"; }

# ---- exit 2: invalid config
fresh; printf 'project: {name: broken}\n' > "$T/factory.yml"; export FACTORY_CONFIG="$T/factory.yml" Q_DEV=26
cycle
t "AC-6 an invalid project config exits 2" test "$RC" = 2
t "AC-6 ... saying so on stderr" in_err "dispatch: invalid config $T/factory.yml"
t "AC-6 ... and nothing on stdout" test -z "$OUT"
t "AC-6 ... and the board is never read" test ! -s "$T/board.calls"
fresh 'pool: 0'; export Q_DEV=26
cycle
t "AC-6 an invalid machine config exits 2" test "$RC" = 2
t "AC-6 ... saying so on stderr" in_err "dispatch: invalid $SHIPFLOOR_HOME/config.yml"
t "AC-6 ... and nothing starts" not launched
fresh; nowhere="$(mktemp -d)"
out="$(cd "$nowhere" && env -u FACTORY_CONFIG -u FACTORY_HOME bash "$D" 2>&1)"; rc=$?
t "AC-6 outside a registered project the cycle exits 2" test "$rc" = 2
assert_contains "$out" "is not in a registered project (shipfloor add <repo>)"

# ---- exit 0: PAUSE, usage limit, GitHub limit
fresh; export Q_DEV=26; touch "$FACTORY_HOME/PAUSE"
cycle
t "AC-6 PAUSE exits 0" test "$RC" = 0
t "AC-6 ... silently" test -z "$OUT$ERR"
t "AC-6 ... without reading the board" test ! -s "$T/board.calls"
fresh; export Q_DEV=26
printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit · resets 6pm\n' > "$FACTORY_HOME/logs/x-5-develop.log"
cycle
t "AC-6 a recent usage limit exits 0" test "$RC" = 0
t "AC-6 ... saying so on stdout" in_out "dispatch: Claude usage limit hit recently; waiting"
t "AC-6 ... nothing on stderr" test -z "$ERR"
t "AC-6 ... and nothing starts" not launched
fresh; export Q_DEV=26; touch "$SHIPFLOOR_HOME/github-limited"
cycle
t "AC-6 a fresh GitHub-limit mark exits 0" test "$RC" = 0
t "AC-6 ... saying so on stdout" in_out "dispatch: GitHub API limit hit recently; waiting"
t "AC-6 ... without reading the board" test ! -s "$T/board.calls"

# ---- exit 1: the board, the cost limits, a step
fresh; export Q_DEV=26 FAIL_ON="snapshot "
cycle
t "AC-6 a failed board read exits 1" test "$RC" = 1
t "AC-6 ... the board's own error passes to stderr" in_err "board: snapshot  failed"
t "AC-6 ... and the dispatcher's line is on stderr" in_err "dispatch: board read failed"
t "AC-6 ... nothing on stdout" test -z "$OUT"
t "AC-6 ... and nothing starts" not launched
fresh; export Q_DEV=26 FAIL_ON="eligible Ready for Refinement"
cycle
t "AC-6 a failed queue read fails the cycle (exit 1)" test "$RC" = 1
t "AC-6 ... the other pipelines still run: develop's card starts" grep -qx '/sf:develop 26' "$T/launched"
fresh $'costs:\n  day_stop: 80'; export Q_DEV=26
printf '#!/usr/bin/env bash\ncase "${2##*/} ${3:-}" in "dashboard_cost.py limits") echo "cost: broken" >&2; exit 1 ;; esac\nexec "$REALPY" "$@"\n' > "$T/py"
chmod +x "$T/py"; export REALPY FACTORY_PYTHON="$T/py"
cycle
t "AC-6 cost limits that cannot be read exit 1" test "$RC" = 1
t "AC-6 ... saying so on stderr" in_err "dispatch: cannot read the cost limits"
t "AC-6 ... and nothing starts" not launched
fresh; export Q_DEV=26 FACTORY_CONTROL_REFRESH=1 FACTORY_REPO="$(mktemp -d)"  # not a git repository: the refresh fails
cycle
t "AC-6 a control checkout that cannot be refreshed exits 1" test "$RC" = 1
t "AC-6 ... saying so on stderr" in_err "dispatch: could not refresh $FACTORY_HOME/control from origin/main"
t "AC-6 ... no run starts" not launched
t "AC-6 ... and no lock is left" test -z "$(ls "$FACTORY_HOME/locks")"

# ---- exit 0: a cycle with nothing to do, and one that starts a run
fresh
cycle
t "AC-6 a cycle with nothing queued exits 0" test "$RC" = 0
fresh; export Q_DEV=26
cycle
t "AC-6 a cycle that starts a run exits 0" test "$RC" = 0
t "AC-6 ... and the run started" grep -qx '/sf:develop 26' "$T/launched"
finish
