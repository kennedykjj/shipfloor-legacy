#!/usr/bin/env bash
# The health history: one line per dispatcher cycle (board, runs against limits, machine) and the
# alerts read back from the last cycles.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
export SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 FAKE_GH_DIR="$(mktemp -d)"
health() { $PY -I "$(nat "$FACTORY_DIR/shipfloor_health.py")" "$1" --home "$(nat "$H")" "${@:2}"; }
last() { tail -1 "$H"/logs/health-*.jsonl | $PY -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
setup() {  # a home with one project: develop has 3 machine slots, refine 2
  H="$(mktemp -d)"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
  printf 'pool: 6\nstages: {refine: 2, develop: 3}\n' > "$H/config.yml"
}
run() { mkdir -p "$P/locks/$1-$2.lock"; echo "$$ $(date +%s) $2" > "$P/locks/$1-$2.lock/info"
        echo "== start /sf:$1 $2 $(date -Is) pid=1" > "$P/logs/$(date +%F)-$2-$1.log"; }

# a line holds the board, the runs against their limits and the machine
setup; printf '26\tReady for Dev\tI26\n27\tReady for Dev\tI27\n30\tCoding\tI30\n33\tDone\tI33\n' > "$P/board.tsv"; run develop 30
health record --seconds 12 --exit 1
assert_contains "$(last 'd["cycle"]')" "{'s': 12, 'exit': 1, 'overlap': False}"
assert_contains "$(last 'sorted(d["projects"]["shop"]["columns"].items())')" "[('Coding', 1), ('Done', 1), ('Ready for Dev', 2)]"
assert_contains "$(last 'd["stages"]["develop"], d["pool"]')" "{'slots': 3, 'running': 1} {'size': 6, 'used': 1}"
assert_contains "$(last 'd["projects"]["shop"]["stages"]["develop"]')" "{'queue': 2, 'orphans': 0, 'running': 1, 'cap': 0}"
[ "$(last 'd["machine"]["disk_free_gb"] > 0')" = True ] && pass "machine: free disk" || fail "no free disk in the line"
assert_contains "$(last 'd["idle"], d["over"]')" "['shop/develop'] []"

# a free slot with cards waiting is an alert only once it lasts: one cycle is the dispatcher's own timing
[ -z "$(health alerts)" ] && pass "one idle cycle is no alert" || fail "alerted on one cycle: $(health alerts)"
health record; health record
assert_contains "$(health alerts)" "shop/develop: a free slot and cards waiting for 3 cycles in a row"

# nothing waits for a slot when the stage is full, the WIP is full, the card is blocked or the factory is paused
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"; run develop 30; run develop 31; run develop 32
health record; assert_contains "$(last 'd["idle"]')" "[]"
setup; printf '26\tReady for Dev\tI26\n1\tCoding\tI1\n2\tCoding\tI2\n3\tValidation\tI3\n4\tValidation\tI4\n' > "$P/board.tsv"
run develop 1; run develop 2; run validate 3; run validate 4
health record; assert_contains "$(last 'd["idle"]')" "[]"
setup; printf '7\tReady for Dev\tI7\n' > "$P/board.tsv"  # the fake gh says card 7 is blocked
health record; assert_contains "$(last 'd["idle"], d["projects"]["shop"]["blocked"]')" "[] 1"
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"; touch "$H/PAUSE"
health record; assert_contains "$(last 'd["idle"], d["paused"]')" "[] True"

# a card left in a work column with no run is waiting to be resumed, whatever the WIP
setup; printf '30\tCoding\tI30\n' > "$P/board.tsv"
health record; assert_contains "$(last 'd["idle"]')" "['shop/develop']"

# more runs than a limit, of the machine or of the project, and two cycles at once are alerts at once
setup; : > "$P/board.tsv"; run refine 40; run refine 41; run refine 42; run deploy 50; run deploy 51
health record --overlap; out="$(health alerts)"
assert_contains "$out" "refine 3/2: more runs than the limit"
assert_contains "$out" "shop/deploy 2/1: more runs than the limit"
assert_contains "$out" "two dispatcher cycles ran at once"

# the dispatcher writes the line at the end of every cycle, and a cycle that finds another one running says so
setup; export SHIPFLOOR_HOME="$H"; : > "$P/board.tsv"; printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fake-dispatch"
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

# costs.day_stop reached: the line says cost_stop and a free slot with cards waiting is no alert (nothing starts, as when paused);
# without costs the line says false. Today's session cost US$ 100 (25M opus input tokens at noon, local time)
CD="$(mktemp -d)"; mkdir -p "$CD/projects/C--x--shipfloor-projects-shop-control"
TZO="$(date +%:z)"
{ printf '{"type":"user","timestamp":"%sT12:00:00%s","message":{"role":"user","content":"<command-name>/sf:develop</command-name>\\n<command-args>26</command-args>"}}\n' "$(date +%F)" "$TZO"
  printf '{"type":"assistant","timestamp":"%sT12:05:00%s","message":{"id":"c1","model":"claude-opus-5-5","usage":{"input_tokens":25000000,"output_tokens":0}}}\n' "$(date +%F)" "$TZO"; } > "$CD/projects/C--x--shipfloor-projects-shop-control/s.jsonl"
export CLAUDE_CONFIG_DIR="$(nat "$CD")"
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"
health record; health record; health record
assert_contains "$(last 'd["cost_stop"]')" "False"
assert_contains "$(health alerts)" "shop/develop: a free slot and cards waiting"
printf 'pool: 6\nstages: {refine: 2, develop: 3}\ncosts:\n  day_stop: 80\n' > "$H/config.yml"
health record; health record; health record
assert_contains "$(last 'd["cost_stop"], d["idle"]')" "True []"
[ -z "$(health alerts)" ] && pass "a day stopped by cost is no free-slot alert" || fail "alerted while the day is stopped: $(health alerts)"
printf 'pool: 6\nstages: {refine: 2, develop: 3}\ncosts:\n  day_stop: 150\n' > "$H/config.yml"
health record; assert_contains "$(last 'd["cost_stop"]')" "False"
unset CLAUDE_CONFIG_DIR

# doctor repeats the alerts
out="$(bash "$FACTORY_DIR/shipfloor" doctor 2>&1)"
assert_contains "$out" "WARN health: two dispatcher cycles ran at once"
finish
