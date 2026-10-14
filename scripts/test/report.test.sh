#!/usr/bin/env bash
# report.sh, metrics.sh and brief.sh (report.py, metrics.py, brief.py). The behavior is in process: py/report_ops.py
# (report + metrics) and py/report_brief.py (brief). Here, the wrappers' contract through real processes: help and
# usage exit codes and streams, one real report pushed, the schema header the skills point to, the metrics TSV and
# its KeyError exit, a brief that never blocks.
source "$(dirname "$0")/lib.sh"
py_suite report_ops
py_suite report_brief

T="$(mktemp -d)"; nodir="$T/nodir"; mkdir -p "$nodir"
# help: exit 0 and the usage on stdout before any project is resolved (wrapper and sf.py)
for a in -h --help help; do
  out="$(cd "$nodir" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$nodir/none" bash "$FACTORY_DIR/report.sh" "$a" 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && [ "${out%%$'\n'*}" = "usage: report.sh <issue> <slug> <pipeline> <report.json> <report.md>" ] && pass "report.sh $a: exit 0, usage on stdout" || fail "report.sh $a: exit $rc: $out"
done
out="$(cd "$nodir" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$nodir/none" "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" report --help 2>&1)"; rc=$?
[ "$rc" = 0 ] && assert_contains "$out" "usage: report.sh" || fail "sf.py report --help: exit $rc: $out"
# a wrong count: exit 2, usage on stderr only
bash "$FACTORY_DIR/report.sh" 1 2 3 > "$T/out" 2> "$T/err"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$T/out" ] && grep -q '^usage: report.sh' "$T/err" && pass "report.sh with 3 arguments: exit 2, usage on stderr only" || fail "report.sh 1 2 3: exit $rc: $(cat "$T/out" "$T/err")"

# one real report through the wrapper: pushed to factory-reports on the remote, main untouched
remote="$T/remote.git"; git init -q --bare -b main "$remote"
r="$(new_repo)"; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
echo '{"issue":26,"slug":"rl","pipeline":"refine","outcome":"ok","agents":[{"role":"po","tokens":1000}],"started_at":"2026-10-09T10:00:00-03:00","finished_at":"2026-10-09T10:12:00-03:00"}' > "$T/r.json"; echo '# R' > "$T/r.md"
assert_exit 0 env FACTORY_HOME="$T/h" FACTORY_REPO="$r" bash "$FACTORY_DIR/report.sh" 26 rl refine "$T/r.json" "$T/r.md"
assert_contains "$(git --git-dir="$remote" ls-tree -r --name-only factory-reports)" "reports/26-rl/refine-"
[ "$(git --git-dir="$remote" rev-list --count main)" = 1 ] && pass "main untouched" || fail "main changed"
# metrics.sh reads it back: exit 0, the header and the row on stdout
out="$(env FACTORY_HOME="$T/h" bash "$FACTORY_DIR/metrics.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = $'issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit\n26\trefine\tok\t1000\t12\t0\t\t' ] && pass "metrics.sh: exit 0, the TSV" || fail "metrics.sh: exit $rc: $out"
# a report without issue: exit 1, Python's KeyError on stderr, the rows before it printed
mkdir -p "$T/h/reports-wt/reports/9-z"; echo '{"pipeline":"refine","outcome":"ok"}' > "$T/h/reports-wt/reports/9-z/refine-1.json"
out="$(env FACTORY_HOME="$T/h" bash "$FACTORY_DIR/metrics.sh" 2> "$T/err")"; rc=$?
[ "$rc" = 1 ] && grep -q "KeyError: 'issue'" "$T/err" && pass "metrics.sh, a report without issue: exit 1 with KeyError" || fail "metrics.sh KeyError: exit $rc: $(cat "$T/err")"
assert_contains "$out" $'26\trefine\tok'

# the header comment (report.sh lines 3-4) is the report.json schema the skills point to
hdr="$(sed -n '3,4p' "$FACTORY_DIR/report.sh")"
case "$hdr" in "# report.json schema: {"*) pass "report.sh line 3 opens the report.json schema" ;; *) fail "report.sh line 3 is not the schema: $hdr" ;; esac
missing=""; for k in issue slug pipeline started_at finished_at outcome agents role tokens duration_s rounds gates_failed flaky gates_reused manual_edit; do
  case "$hdr" in *"\"$k\""*) ;; *) missing="$missing $k" ;; esac
done
[ -z "$missing" ] && pass "the schema names every report.json field" || fail "the schema lacks:$missing"
assert_contains "$hdr" '"outcome":"ok|blocked|infra"'
assert_contains "$hdr" '"agents":[{"role","tokens","duration_s"}]'

# brief.sh never blocks: bad arguments are one 'brief: skipped:' line on stderr, exit 0
(cd "$T" && bash "$FACTORY_DIR/brief.sh" build 7 --column Nope > "$T/out" 2> "$T/err"); rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/out" ] && [ "$(wc -l < "$T/err" | tr -d ' ')" = 1 ] && grep -q '^brief: skipped: ' "$T/err" && pass "brief.sh with bad arguments: exit 0, one skipped line" || fail "brief.sh: exit $rc: $(cat "$T/out" "$T/err")"
finish
