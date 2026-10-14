#!/usr/bin/env bash
# #160 AC-2: what a launch passes to the run, pinned as it is today.
#  - the Read(//…/reports-wt/**) rule is passed only when $FACTORY_HOME/reports-wt exists
#  - SHIPFLOOR_INFRA_RETRY=1 is passed only when infra/<n> exists
#  - --model and weight= on the == start line: the model matches dashboard.py's own regex (RUN_MODEL, read out of the
#    source here, not copied) and the --model flag; weight= closes the line (dashboard.py has no regex for it)
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export FACTORY_CONTROL_REFRESH=0
tmp="$(mktemp -d)"
BASE_CONFIG="$FACTORY_CONFIG"

# the board: card 54 (and 55) wait in Ready for Dev, 60 in Validation, 70 in Ready for Refinement; infra lists the cards blocked by it
cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Dev") echo "${Q_DEV:-}" ;;
  "eligible Validation") echo "${Q_VAL:-}" ;;
  "eligible Ready for Refinement") echo "${Q_REF:-}" ;;
  "infra ") echo "${Q_INFRA:-}" ;;
  "eligible "*|"label "*) ;;
  *) echo 0 ;;
esac
EOB
# the run: one line with what it was given
printf '#!/usr/bin/env bash\necho "retry=${SHIPFLOOR_INFRA_RETRY:-unset} prompt=$(cat) args=$*"\n' > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
# dashboard.py's regex for the model of a start line, read out of its source (never copied here)
cat > "$tmp/match.py" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^RUN_MODEL = re\.compile\(r"(.*?)"\)', src, re.M)
if not m:
    sys.exit(3)
hit = re.compile(m.group(1)).search(sys.argv[2])
print(hit.group(1) if hit else "")
PY

fresh() {  # fresh [machine config text]: a new home; nothing queued
  export FACTORY_HOME="$(mktemp -d)" SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONFIG="$BASE_CONFIG"
  mkdir -p "$FACTORY_HOME/control"
  { printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n'; [ -z "${1:-}" ] || printf '%s\n' "$1"; } > "$SHIPFLOOR_HOME/config.yml"
  export Q_DEV= Q_VAL= Q_REF= Q_INFRA=
}
log_of() { cat "$FACTORY_HOME"/logs/*-"$2-$1.log" 2>/dev/null | tr -d '\r'; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3: no '$2' in: ${1:0:500}" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3: found '$2' in: ${1:0:500}" ;; *) pass "$3" ;; esac; }
not() { ! "$@"; }
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
startline() { log_of "$1" "$2" | grep '^== start' | tail -n 1; }
runmodel() { "$FACTORY_PYTHON" -I "$tmp/match.py" "$FACTORY_DIR/dashboard.py" "$1" | tr -d '\r'; }  # dashboard's model of a start line
flagmodel() { log_of "$1" "$2" | grep -o -e '--model [a-z0-9.-]*' | tail -n 1 | cut -d' ' -f2; }
card() {  # card <n> <weight>: card <n>'s worktree on feat/<n>-thing, its spec header naming the weight; "-" = no spec
  local wt="$FACTORY_WT_ROOT/$1"; rm -rf "$wt"; cp -r "$(new_repo)" "$wt"
  git -C "$wt" checkout -q -b "feat/$1-thing"
  [ "$2" = - ] && return 0
  mkdir -p "$wt/docs/superpowers/specs"
  printf '# Thing — spec\n\n**Issue:** #%s\n**Roles:** PO, Tech Lead\n**Weight:** %s\n\n## Product\n- **AC-1** — x\n' "$1" "$2" > "$wt/docs/superpowers/specs/2026-10-12-thing-design.md"
}

t "AC-2 dashboard.py's start-line regex was found in its source" test -n "$("$FACTORY_PYTHON" -I -c 'import re,sys; print(re.search(r"^RUN_MODEL = re", open(sys.argv[1], encoding="utf-8").read(), re.M) is not None)' "$FACTORY_DIR/dashboard.py" | grep True)"

# ---- the reports-wt rule: only when the folder exists
fresh; Q_DEV=54; export Q_DEV
run_dispatch; log="$(log_of develop 54)"
factory_rule="Read(/$(cd "$FACTORY_DIR" && pwd)/**)"
has "$log" "--allowedTools $factory_rule --disallowedTools PowerShell" "AC-2 without reports-wt: only the factory's own rule is passed"
lacks "$log" "reports-wt" "AC-2 without reports-wt: no rule names it"
t "AC-2 without reports-wt: exactly one Read rule" test "$(grep -o 'Read(' <<< "$log" | grep -c .)" = 1
fresh; mkdir -p "$FACTORY_HOME/reports-wt"; Q_DEV=54; export Q_DEV
run_dispatch; log="$(log_of develop 54)"
reports_rule="Read(/$(cd "$FACTORY_HOME/reports-wt" && pwd)/**)"
has "$log" "--allowedTools $factory_rule $reports_rule --disallowedTools PowerShell" "AC-2 with reports-wt: its rule follows the factory's"
has "$log" "Read(//" "AC-2 an absolute path in a rule opens with two slashes"
t "AC-2 with reports-wt: the rule ends in reports-wt/**)" grep -q 'reports-wt/\*\*)' <<< "$log"
t "AC-2 with reports-wt: two Read rules" test "$(grep -o 'Read(' <<< "$log" | grep -c .)" = 2
t "AC-2 the rule only reads: no Write or Edit rule is passed" not grep -qE 'Write\(|Edit\(' <<< "$log"

# ---- SHIPFLOOR_INFRA_RETRY=1: only for a card with infra/<n>
fresh; Q_DEV="54 55"; Q_INFRA=54; export Q_DEV Q_INFRA
run_dispatch
has "$(log_of develop 54)" "retry=1 " "AC-2 a card the infra retry just reopened is launched with SHIPFLOOR_INFRA_RETRY=1"
has "$(log_of develop 55)" "retry=unset " "AC-2 a card with no infra/<n> gets no SHIPFLOOR_INFRA_RETRY"
t "AC-2 the marker infra/54 stays after the launch (the next block goes to the owner)" test -f "$FACTORY_HOME/infra/54"
t "AC-2 no marker for the other card" test ! -e "$FACTORY_HOME/infra/55"
run_dispatch   # the card blocked by infrastructure again: the marker is spent and the run has no retry flag
has "$(log_of develop 54 | grep -o 'retry=[a-z0-9]*' | tail -n 1)" "retry=unset" "AC-2 after a second block, the run is launched without SHIPFLOOR_INFRA_RETRY"
t "AC-2 the second block removes the marker" test ! -e "$FACTORY_HOME/infra/54"
fresh; Q_DEV=54; export Q_DEV
run_dispatch
has "$(log_of develop 54)" "retry=unset " "AC-2 with no infra marker at all, no SHIPFLOOR_INFRA_RETRY"

# ---- --model and weight= on the == start line, with dashboard.py's regex
fresh; card 54 light; card 60 heavy; card 55 standard; Q_DEV="54 55"; Q_VAL=60; export Q_DEV Q_VAL
run_dispatch
for w in "develop 54 sonnet light" "develop 55 sonnet standard" "validate 60 sonnet heavy"; do
  set -- $w; line="$(startline "$1" "$2")"
  t "AC-2 $1 #$2: the start line is '== start /sf:$1 $2 <date> pid=<n> model=$3 weight=$4'" grep -Eq "^== start /sf:$1 $2 [0-9T:+.Z-]+ pid=[0-9]+ model=$3 weight=$4\$" <<< "$line"
  t "AC-2 $1 #$2: dashboard.py's regex reads model $3 from the start line" test "$(runmodel "$line")" = "$3"
  t "AC-2 $1 #$2: the model on the start line is the --model flag the run got" test "$(flagmodel "$1" "$2")" = "$3"
done
fresh; card 54 heavy; Q_DEV=54; export Q_DEV
run_dispatch; line="$(startline develop 54)"
has "$line" " model=opus weight=heavy" "AC-2 a heavy card's develop run: model=opus weight=heavy"
t "AC-2 dashboard.py's regex reads opus" test "$(runmodel "$line")" = "opus"
t "AC-2 --model opus is the flag" test "$(flagmodel develop 54)" = "opus"
t "AC-2 weight= is the last field of the line" grep -Eq ' weight=(light|standard|heavy)$' <<< "$line"
fresh $'models:\n  stages:\n    develop: {light: haiku}'; card 54 light; Q_DEV=54; export Q_DEV
run_dispatch; line="$(startline develop 54)"
t "AC-2 a model the machine config sets (haiku) is the one dashboard.py reads" test "$(runmodel "$line")" = "haiku"
has "$line" " model=haiku weight=light" "AC-2 ... with its weight"
fresh $'models:\n  stages:\n    develop: fable'; card 54 standard; Q_DEV=54; export Q_DEV
run_dispatch; line="$(startline develop 54)"
t "AC-2 a single model for the stage (fable) fills the weight: dashboard.py reads it" test "$(runmodel "$line")" = "fable"
# no spec: standard; refine runs before the card has a weight
fresh; Q_REF=70; export Q_REF
run_dispatch; line="$(startline refine 70)"
has "$line" " model=sonnet weight=standard" "AC-2 a card with no spec runs as standard: refine's start line"
t "AC-2 dashboard.py reads refine's model" test "$(runmodel "$line")" = "sonnet"
# the regex wants the leading space of " model=": a line with no model gives none (what the dashboard shows for a legacy run)
t "AC-2 the regex reads nothing from a start line without model=" test -z "$(runmodel '== start /sf:develop 9 2026-10-14T10:00:00-03:00 pid=1')"
finish
