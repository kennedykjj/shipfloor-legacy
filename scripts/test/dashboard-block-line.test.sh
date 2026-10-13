#!/usr/bin/env bash
# A blocked card says why in the list: the overview carries block_line, the one line of the factory's note that
# states the owner's call (else the failed gate, else nothing), and block_cost for a block by the cost limit.
# A card blocked by infrastructure has no line there; its tile in "In progress" says so.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews" "$P/cost"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
for n in 7 8 9 10 11 12 13; do printf '%s\tCoding\n' "$n"; done > "$P/board.tsv"
echo '[{"number":7},{"number":8},{"number":9},{"number":10},{"number":13}]' > "$FAKE_GH_DIR/label-blocked"
echo '[{"number":11}]' > "$FAKE_GH_DIR/label-blocked-infra"
note() { $PY -c 'import json,sys; print(json.dumps([{"body":"Spec ready"},{"body":sys.argv[1]}]))' "$1" > "$FAKE_GH_DIR/comments-$2"; }
note $'**Develop blocked** at step 4: the API answers 410.\n- **The owner must decide:** keep the `v1` endpoint or drop it\nTried: two rounds.' 7
note $'**Develop blocked** at step 3: the tests timed out twice.' 8
note $'**Validate blocked.** Failed gates: **acceptance-intact**. The test files changed after QA.' 9
note $'Cost limit: blocked. The card spent $7.50 est.' 10
note $'**Validate blocked (infrastructure)**: the stack did not come up.' 11
note "**Develop blocked.** Needs you to: $(printf 'pick one %.0s' $(seq 1 80))" 13
printf '{"total": 7.5, "baseline": 2.5, "limit": 5, "stages": {"develop": 5.0}}' > "$P/cost/10.json"

export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
curl -s -H "X-Shipfloor-Token: $tok" "$base/api/overview" > "$FAKE_GH_DIR/overview.json"
card() {  # card <n>: "blocked|block_line|block_cost" from the overview
  $PY -c 'import json,sys; c=next(c for c in json.load(open(sys.argv[1], encoding="utf-8"))["projects"][0]["cards"] if c["issue"]==int(sys.argv[2])); print("|".join([str(c.get("blocked")), c.get("block_line", "<missing>"), json.dumps(c.get("block_cost", "<missing>"), sort_keys=True)]))' "$(nat "$FAKE_GH_DIR/overview.json")" "$1" | tr -d '\r'
}
want() { [ "$2" = "$3" ] && pass "$1" || fail "$1: got '$2', want '$3'"; }

# AC-1: the owner's call, without its label, marks stripped, first letter in capitals
want "AC-1 the line is what the owner must decide" "$(card 7)" "owner|Keep the v1 endpoint or drop it|null"
# a long call is bounded in the payload; the page cuts it to one line
len="$(card 13 | cut -d'|' -f2 | tr -d '\n' | wc -c | tr -d ' ')"
[ "$len" -le 500 ] && [ "$len" -gt 100 ] && pass "AC-1 a long call is bounded at 500 characters ($len)" || fail "AC-1 a long call is $len characters"
# AC-2: no call and no failed gate: no line, nothing invented
want "AC-2 a note with no reason gives no line" "$(card 8)" "owner||null"
want "AC-2 the failed gate when the note names one" "$(card 9)" "owner|Failed gate: acceptance-intact|null"
want "AC-2 a card that is not blocked has no line" "$(card 12)" "None||null"
want "AC-2 a block by the cost limit carries its figures, not a line" "$(card 10)" 'owner||{"baseline": 2.5, "limit": 5, "total": 5.0}'
# AC-3: an infrastructure block asks for no decision: no line in the list, and the tile says what happened
want "AC-3 an infrastructure block has no line" "$(card 11)" "infra||null"
h="$(cat "$FACTORY_DIR/dashboard.html")"
assert_contains "$h" 'if (c.blocked === "infra") return t("why.infra");'
[ "$(en_msg why.infra)" = "Infrastructure failed; the factory retries once" ] && pass "AC-3 the tile says the infrastructure failed and the factory retries once" || fail "AC-3 why.infra is: $(en_msg why.infra)"
case "$h$(cat "$FACTORY_DIR/lang/dashboard.en.json")" in *"Blocked by infrastructure; the factory retries it"*) fail "AC-3 the old infrastructure wording is still there" ;; *) pass "AC-3 the old infrastructure wording is gone" ;; esac
# the pass shows the line only for an owner block, through esc: the factory's own words, never a message; only a
# failed gate's label is the page's (pass.failed_gate)
ph="$(sed -n '/^function passHtml/,/^}/p' "$FACTORY_DIR/dashboard.html")"
assert_contains "$ph" 'class="pwhy"'
assert_contains "$ph" 'esc(c.block_line)'
assert_contains "$ph" 't(c.block_cost ? "q.blocked_cost" : "pass.blocked")'
[ "$(en_msg q.blocked_cost)" = "Blocked · cost limit" ] && pass "AC-1 a block by the cost limit reads Blocked · cost limit" || fail "AC-1 q.blocked_cost is: $(en_msg q.blocked_cost)"
assert_contains "$ph" 't("pass.failed_gate", { gate: esc(gate[1]) })'
grep -qE '\.pwhy \{[^}]*white-space: nowrap[^}]*text-overflow: ellipsis' "$FACTORY_DIR/dashboard.html" && pass "AC-1 the line is one line, cut by an ellipsis" || fail "AC-1 .pwhy does not stay on one line"
finish
