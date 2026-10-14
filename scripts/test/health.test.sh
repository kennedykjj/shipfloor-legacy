#!/usr/bin/env bash
# suite: integration
# The health history (shipfloor_health.py): one line per dispatcher cycle and the alerts read back from the last ones.
# The behavior is in process (py/health_record.py: the line, idle slots, limits, pauses, cost stop, working hours,
# dependencies, missed cycles and silence(), the platform probes). Here, through real processes: shipfloor_health.py's command line
# (record with the real stack status, alerts), shipfloor-dispatch.sh writing the line at the end of each cycle, with
# the overlap marker, and `shipfloor doctor` repeating the alerts.
source "$(dirname "$0")/lib.sh"
py_suite health_record
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
export SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 FAKE_GH_DIR="$(mktemp -d)"
health() { $PY -I "$(nat "$FACTORY_DIR/shipfloor_health.py")" "$1" --home "$(nat "$H")" "${@:2}"; }
last() { tail -1 "$H"/logs/health-*.jsonl | $PY -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
H="$(mktemp -d)"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
printf 'pool: 6\nstages: {refine: 2, develop: 3}\n' > "$H/config.yml"
printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"

# the command line: record appends a line to logs/health-<YYYY-MM>.jsonl, alerts prints one alert a line
health record --seconds 12 --exit 1 --overlap; rc=$?
[ "$rc" = 0 ] && [ -f "$H/logs/health-$(date +%Y-%m).jsonl" ] && pass "record: exit 0, the month's file" || fail "record: exit $rc, $(ls "$H/logs")"
assert_contains "$(last 'd["cycle"], d["idle"]')" "{'s': 12, 'exit': 1, 'overlap': True} ['shop/develop']"
assert_contains "$(last 'sorted(d["stacks"])')" "['busy', 'queue', 'total']"
assert_contains "$(health alerts)" "two dispatcher cycles ran at once"
assert_exit 2 health bogus

# the dispatcher writes the line at the end of every cycle, and a cycle that finds another one running says so
export SHIPFLOOR_HOME="$H"; : > "$P/board.tsv"; printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fake-dispatch"
r="$(new_repo)"; mkdir -p "$r/.shipfloor"; cp "$FACTORY_DIR/test/fixture/factory.yml" "$r/.shipfloor/factory.yml"
git -C "$r" add -A; git -C "$r" commit -qm config; git -C "$r" worktree add -q --detach "$P/control" main
printf 'shop\t%s\t%s\tmain\n' "$r" "$H/wt" > "$H/registry.tsv"
FACTORY_CONTROL_REFRESH=0 SHIPFLOOR_DISPATCH="$H/fake-dispatch" bash "$FACTORY_DIR/shipfloor-dispatch.sh"
assert_contains "$(last 'd["cycle"]["exit"], d["cycle"]["overlap"]')" "0 False"
[ ! -e "$H/dispatch.pid" ] && pass "the cycle's marker is gone when it ends" || fail "left dispatch.pid behind"
echo $$ > "$H/dispatch.pid"  # this test's own shell stands for a cycle still running
FACTORY_CONTROL_REFRESH=0 SHIPFLOOR_DISPATCH="$H/fake-dispatch" bash "$FACTORY_DIR/shipfloor-dispatch.sh"
assert_contains "$(last 'd["cycle"]["overlap"]')" "True"
[ "$(cat "$H/dispatch.pid")" = $$ ] && pass "the running cycle keeps its marker" || fail "the second cycle took the marker"
touch "$H/PAUSE"; rm "$H/dispatch.pid"; bash "$FACTORY_DIR/shipfloor-dispatch.sh"
assert_contains "$(last 'd["paused"]')" "True"

# doctor repeats the alerts (the second cycle above overlapped), with the project's control checkout
out="$(bash "$FACTORY_DIR/shipfloor" doctor 2>&1)"
assert_contains "$out" "WARN health: two dispatcher cycles ran at once"
assert_contains "$out" "WARN shop: control checkout is behind origin/main"

# #176: the doctor warns of a silent dispatcher past 3 x the pace (silence()), and says nothing at 2 x or with no line
S="$(mktemp -d)"; mkdir -p "$S/logs"; printf 'dispatcher: {every_min: 10}\n' > "$S/config.yml"
cyc() { $PY -I -c 'import json,sys; from datetime import datetime,timedelta; t=(datetime.now().astimezone()-timedelta(minutes=float(sys.argv[1]))).isoformat(timespec="seconds"); print(json.dumps({"ts":t,"cycle":{"s":5,"exit":0,"overlap":False},"paused":False,"idle":[],"over":[]}))' "$1" > "$S/logs/health-$(date +%Y-%m).jsonl"; }
out="$(SHIPFLOOR_HOME="$S" bash "$FACTORY_DIR/shipfloor" doctor 2>&1)"
case "$out" in *"no dispatcher cycle"*) fail "the doctor warned with no health line: $out" ;; *) pass "the doctor is quiet with no health line" ;; esac
cyc 20; out="$(SHIPFLOOR_HOME="$S" bash "$FACTORY_DIR/shipfloor" doctor 2>&1)"
case "$out" in *"no dispatcher cycle"*) fail "the doctor warned at 2 x the pace: $out" ;; *) pass "the doctor is quiet at 2 x the pace" ;; esac
cyc 60; out="$(SHIPFLOOR_HOME="$S" bash "$FACTORY_DIR/shipfloor" doctor 2>&1)"
assert_contains "$out" "WARN health: no dispatcher cycle for 60 min (it runs every 10)"
finish
