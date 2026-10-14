#!/usr/bin/env bash
# metrics.sh (#161, PY-08): one TSV line per report; what it does today with a report that lacks a field, and with no FACTORY_HOME.
source "$(dirname "$0")/lib.sh"
METRICS="$FACTORY_DIR/metrics.sh"
mkhome() {  # mkhome: a home with an empty reports folder (no git worktree: the pull in metrics.sh fails quietly); prints it
  local h; h="$(mktemp -d)"; mkdir -p "$h/reports-wt/reports"; echo "$h"
}
put() {  # put <home> <dir> <file> <json>
  mkdir -p "$1/reports-wt/reports/$2"; printf '%s\n' "$4" > "$1/reports-wt/reports/$2/$3"
}
HEADER=$'issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit'

# the output of a good report: the columns, in order
h="$(mkhome)"
put "$h" 10-a develop-1.json '{"issue":10,"slug":"a","pipeline":"develop","outcome":"blocked","agents":[{"role":"qa","tokens":300},{"role":"eng","tokens":null}],"rounds":{"qa":2,"eng":1},"gates_failed":["build","red"],"manual_edit":true,"started_at":"2026-10-09T10:00:00-03:00","finished_at":"2026-10-09T10:30:00-03:00"}'
out="$(env FACTORY_HOME="$h" bash "$METRICS")"
[ "$out" = "$HEADER"$'\n'$'10\tdevelop\tblocked\t300\t30\t3\tbuild,red\tTrue' ] && pass "AC-4 a good report is one line: issue pipeline outcome tokens minutes rounds gates_failed manual_edit" || fail "AC-4 output: $out"

# a report without started_at or finished_at is not a crash: the duration is empty
h="$(mkhome)"
put "$h" 11-b refine-1.json '{"issue":11,"pipeline":"refine","outcome":"ok"}'
out="$(env FACTORY_HOME="$h" bash "$METRICS")"
[ "$out" = "$HEADER"$'\n'$'11\trefine\tok\t0\t\t0\t\t' ] && pass "AC-4 no started_at/finished_at: empty duration, not a crash" || fail "AC-4 output without times: $out"

# a report without issue, pipeline or outcome crashes the script: Python's KeyError, exit 1. The header and the rows sorted before it
# are already printed, and the rows after it are never read.
for k in issue pipeline outcome; do
  h="$(mkhome)"
  good='{"issue":1,"pipeline":"refine","outcome":"ok"}'
  bad="$(printf '{"issue":2,"pipeline":"refine","outcome":"ok"}' | "$FACTORY_PYTHON" -I -c 'import json,sys; d=json.load(sys.stdin); del d[sys.argv[1]]; print(json.dumps(d))' "$k")"
  put "$h" 1-a refine-1.json "$good"; put "$h" 2-b refine-1.json "$bad"; put "$h" 3-c refine-1.json '{"issue":3,"pipeline":"refine","outcome":"ok"}'
  assert_exit 1 env FACTORY_HOME="$h" bash "$METRICS"
  out="$(env FACTORY_HOME="$h" bash "$METRICS" 2> "$h/err")"
  assert_contains "$(cat "$h/err")" "KeyError: '$k'"
  [ "$out" = "$HEADER"$'\n'$'1\trefine\tok\t0\t\t0\t\t' ] && pass "AC-4 missing $k: the header and the earlier report are printed, nothing after the crash" || fail "AC-4 missing $k, stdout: $out"
done

# FACTORY_HOME unset while FACTORY_CONFIG is set: the config resolves, then the script stops on the unbound variable, exit 1
assert_exit 1 env -u FACTORY_HOME FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" bash "$METRICS"
out="$(env -u FACTORY_HOME LC_ALL=C LANGUAGE= FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" bash "$METRICS" 2>&1)"
assert_contains "$out" "FACTORY_HOME: unbound variable"
case "$out" in *"$HEADER"*) fail "AC-4 the table was printed without a home" ;; *) pass "AC-4 nothing is printed without a home" ;; esac
finish
