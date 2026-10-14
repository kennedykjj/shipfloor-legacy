#!/usr/bin/env bash
# #168 AC-5: the cycle's policies act as before the port. Outside working hours only new runs are skipped (the infra
# retry, the marker cleanup and the tmp sweep still run); the usage-limit stop looks back 30 minutes; the step-up is for
# develop only; the infra retry clears tmp/<n>/ and relaunches once with SHIPFLOOR_INFRA_RETRY=1; refresh_staged runs
# only when the project turns it on, under its own refresh-<n>.lock.
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
BASE_CONFIG="$FACTORY_CONFIG"
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }

fresh() {  # fresh [machine config text]: a new home; queues from Q_*, the infra list from Q_INFRA, snapshot from BSNAP
  T="$(mktemp -d)"; export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_PROJECT=shop
  export Q_DEV= Q_VAL= Q_STG= Q_INFRA= BSNAP= VERDICT=
  unset SHIPFLOOR_NOW
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  { printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n'; [ -z "${1:-}" ] || printf '%s\n' "$1"; } > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "snapshot ") printf '%b' "${BSNAP:-}" ;;
  "infra ") echo "${Q_INFRA:-}" ;;
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Validation") echo "${Q_VAL:-}" ;;
  "eligible Staged") echo "${Q_STG:-}" ;;
  "label "*) echo "$*" >> "$T/labels" ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
echo "$(cat) retry=${SHIPFLOOR_INFRA_RETRY:-0}" >> "$T/launched"
[ -z "${VERDICT:-}" ] || printf 'build\t%s\n' "$VERDICT" > "$SHIPFLOOR_RUN_LOCK/last-gate"
EOC
  cat > "$T/deploy" <<'EOD'
#!/usr/bin/env bash
{ echo "$*"; ls "$FACTORY_HOME/locks"; } >> "$T/deploy.calls"
EOD
  chmod +x "$T/board" "$T/claude" "$T/deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude" FACTORY_DEPLOY="$T/deploy"
}
launched() { grep -q "^$1 " "$T/launched" 2>/dev/null; }

# ---- working hours: only the starts are skipped
fresh 'hours: ["08:00-09:00"]'; export SHIPFLOOR_NOW=12:00 Q_DEV=54 Q_INFRA=70 BSNAP='5\tDone\tI_5\n70\tValidation\tI_70\n'
mkdir -p "$FACTORY_HOME/tmp/5" "$FACTORY_HOME/tmp/70/junk" "$FACTORY_HOME/stepup"; printf 'sonnet\topus\tbuild\n' > "$FACTORY_HOME/stepup/9"
out="$(run_dispatch 2>&1)"; rc=$?
t "AC-5 outside the hours no run starts" not launched '/sf:develop 54'
t "AC-5 ... the cycle exits 0" test "$rc" = 0
t "AC-5 ... the infra retry still runs (marker written)" test -f "$FACTORY_HOME/infra/70"
t "AC-5 ... its label comes off" grep -qx 'label 70 remove blocked:infra' "$T/labels"
t "AC-5 ... its tmp/70/ is cleaned" test ! -e "$FACTORY_HOME/tmp/70"
t "AC-5 ... the tmp sweep still runs" test ! -e "$FACTORY_HOME/tmp/5"
t "AC-5 ... and a step-up marker of a card gone from the board still goes" test ! -e "$FACTORY_HOME/stepup/9"
assert_contains "$out" "dispatch: outside working hours; runs start again at 08:00"

# ---- the infra retry relaunches once, with SHIPFLOOR_INFRA_RETRY=1
fresh; export Q_INFRA=70 Q_VAL=70
run_dispatch >/dev/null 2>&1
t "AC-5 a card blocked by infrastructure is relaunched with SHIPFLOOR_INFRA_RETRY=1" grep -qx '/sf:validate 70 retry=1' "$T/launched"

# ---- the usage-limit stop looks back 30 minutes
limit_log() { printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit\n' > "$FACTORY_HOME/logs/x-5-develop.log"; touch -d "$1" "$FACTORY_HOME/logs/x-5-develop.log"; }
fresh; export Q_DEV=54; limit_log '-25 minutes'
run_dispatch >/dev/null 2>&1
t "AC-5 a usage limit 25 minutes ago still stops new runs" not launched '/sf:develop 54'
fresh; export Q_DEV=54; limit_log '-35 minutes'
run_dispatch >/dev/null 2>&1
t "AC-5 a usage limit 35 minutes ago does not" launched '/sf:develop 54'
fresh; export Q_DEV=54; mkdir -p "$FACTORY_HOME/logs/old"; printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit\n' > "$FACTORY_HOME/logs/old/y-5-develop.log"
run_dispatch >/dev/null 2>&1
t "AC-5 a log in a folder under logs/ counts too" not launched '/sf:develop 54'

# ---- the step-up is for develop only
fresh; export Q_VAL=60 VERDICT=FAIL
run_dispatch >/dev/null 2>&1
t "AC-5 a validate run that ends on a failed gate does not step up" test ! -e "$FACTORY_HOME/stepup/60"
t "AC-5 ... and no label is touched" test ! -e "$T/labels"
fresh; export Q_DEV=54 VERDICT=FAIL
run_dispatch >/dev/null 2>&1
t "AC-5 contrast: a develop run on a failed gate does" test -f "$FACTORY_HOME/stepup/54"

# ---- refresh_staged: off by default, on when the project says so, under refresh-<n>.lock
fresh; export Q_STG=35
run_dispatch >/dev/null 2>&1
t "AC-5 refresh_staged is off by default" test ! -e "$T/deploy.calls"
fresh; export Q_STG=35
sed 's/environment: production}/environment: production, refresh_staged: true}/' "$BASE_CONFIG" > "$T/factory.yml"; export FACTORY_CONFIG="$T/factory.yml"
run_dispatch >/dev/null 2>&1
t "AC-5 with refresh_staged: true, deploy.sh <n> --refresh runs" test "$(head -n 1 "$T/deploy.calls" 2>/dev/null)" = "35 --refresh"
t "AC-5 ... while it holds refresh-35.lock" grep -qx 'refresh-35.lock' "$T/deploy.calls"
t "AC-5 ... which goes when it ends" test ! -e "$FACTORY_HOME/locks/refresh-35.lock"
t "AC-5 ... and its log is <date>-35-refresh.log" test -f "$FACTORY_HOME/logs/$(date +%F)-35-refresh.log"
finish
