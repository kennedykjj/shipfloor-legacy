#!/usr/bin/env bash
# The health line does not count a queued card that waits only on dependencies as an idle slot (#202).
# The dispatcher's record is <project home>/deps.json: {"<n>": {"read": true|false, "deps": [{"n", "title", "state"}]}}.
#   AC-5  a card with an open dependency (or whose dependencies could not be read) is not "waiting" for a free slot
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
export SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 FAKE_GH_DIR="$(mktemp -d)"
health() { $PY -I "$(nat "$FACTORY_DIR/shipfloor_health.py")" "$1" --home "$(nat "$H")" "${@:2}"; }
last() { tail -1 "$H"/logs/health-*.jsonl | $PY -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
setup() {  # a home with one project: develop has 3 machine slots
  H="$(mktemp -d)"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
  printf 'pool: 6\nstages: {refine: 2, develop: 3}\n' > "$H/config.yml"
}
OPEN='{"n": 162, "title": "The base", "state": "open"}'
CLOSED='{"n": 163, "title": "Done base", "state": "closed"}'

# control: the card with no record is waiting for a free slot (the same as in health.test.sh)
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"
health record; assert_contains "$(last 'd["idle"]')" "['shop/develop']"

# AC-5: the only queued card waits on an open dependency: the slot is not idle
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"
printf '{"26": {"read": true, "deps": [%s]}}\n' "$OPEN" > "$P/deps.json"
health record; assert_contains "$(last 'd["idle"]')" "[]"
health record; health record
[ -z "$(health alerts)" ] && pass "AC-5 a card waiting on a dependency is no free-slot alert" || fail "AC-5 alerted: $(health alerts)"

# AC-5: open and closed dependencies together still wait
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"
printf '{"26": {"read": true, "deps": [%s, %s]}}\n' "$CLOSED" "$OPEN" > "$P/deps.json"
health record; assert_contains "$(last 'd["idle"]')" "[]"

# AC-5: dependencies the dispatcher could not read: the card is not started, so the slot is not idle
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"
printf '{"26": {"read": false, "deps": []}}\n' > "$P/deps.json"
health record; assert_contains "$(last 'd["idle"]')" "[]"

# AC-5: only closed dependencies: the card can start, so a free slot is idle
setup; printf '26\tReady for Dev\tI26\n' > "$P/board.tsv"
printf '{"26": {"read": true, "deps": [%s]}}\n' "$CLOSED" > "$P/deps.json"
health record; assert_contains "$(last 'd["idle"]')" "['shop/develop']"

# AC-5: a second queued card with no dependency keeps the slot idle
setup; printf '26\tReady for Dev\tI26\n27\tReady for Dev\tI27\n' > "$P/board.tsv"
printf '{"26": {"read": true, "deps": [%s]}}\n' "$OPEN" > "$P/deps.json"
health record; assert_contains "$(last 'd["idle"]')" "['shop/develop']"

# AC-5: an orphan (a card left in Coding with no run) waiting on a dependency is not resumed, so not idle
setup; printf '30\tCoding\tI30\n' > "$P/board.tsv"
printf '{"30": {"read": true, "deps": [%s]}}\n' "$OPEN" > "$P/deps.json"
health record; assert_contains "$(last 'd["idle"]')" "[]"
finish
