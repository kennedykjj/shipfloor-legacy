#!/usr/bin/env bash
# The dispatcher does not start a card with an open "Blocked by" dependency (#202), with the real board.sh over the fake gh.
# $FAKE_GH_DIR/blocked-by-<n> holds the dependencies of card <n> (a JSON array), fail-deps makes the read fail, dep-calls logs it.
#   AC-1  an open dependency: not started, no label, still in the queue, the next card starts
#   AC-2  the dependency closes: the next cycle starts the card
#   AC-3  a dependency closed as "not planned" does not block, and deps.json records it as closed
#   AC-6  REST read, at most one call per candidate per cycle; an API error leaves the card not started and not blocked
#   AC-7  refinement never waits on dependencies
#   AC-8  the open, closed and error scenarios are each asserted
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
PY=python3; $PY -c '' 2>/dev/null || PY=python
setup() {
  export SHIPFLOOR_HOME="$(mktemp -d)"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
  unset SHIPFLOOR_MAX_PARALLEL FAKE_GH_NO_JQ
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/logs"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$SHIPFLOOR_HOME/registry.tsv"
  printf 'pool: 4\nstages: {refine: 1, develop: 1, validate: 1, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  tmp="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "$(cat) $*" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  printf '#!/usr/bin/env bash\necho "deploy $*" >> "%s/launched"\n' "$tmp" > "$tmp/deploy"
  chmod +x "$tmp/claude" "$tmp/deploy"
  printf '#!/usr/bin/env bash\nexec bash "%s/board.sh" "$@"\n' "$FACTORY_DIR" > "$tmp/board"; chmod +x "$tmp/board"
  export FACTORY_CLAUDE="$tmp/claude" FACTORY_DEPLOY="$tmp/deploy" FACTORY_BOARD="$tmp/board"
  : > "$tmp/launched"
}
launched() { cat "$tmp/launched"; }
open_dep='[{"number":162,"title":"The base","state":"open"}]'
# dep_calls <n>: how many dependency reads the fake gh logged for card <n>
dep_calls() { if [ -f "$FAKE_GH_DIR/dep-calls" ]; then grep -c "issues/$1/dependencies/blocked_by" "$FAKE_GH_DIR/dep-calls" | tr -d '\r'; else echo 0; fi; }
# touched <n>: gh was asked to label or edit card <n> (a block would add the label "blocked")
touched() { grep -E "issues/$1/labels|label.*$1|item-edit.*$1" "$FAKE_GH_DIR/calls" 2>/dev/null | grep -v dependencies; }
# deps_json <python expr on d>: the dispatcher's record of the dependencies it read
deps_json() { $PY -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FACTORY_HOME/deps.json" "$1" 2>&1 | tr -d '\r'; }
not_started() {  # not_started <what> <n>
  case "$(launched)" in *"/sf:develop $2"*) fail "$1: #$2 was started" ;; *) pass "$1: #$2 was not started" ;; esac
}

# AC-1 + AC-8 (open): the top card waits on an open issue; it is skipped and the next card starts
setup
printf 'PVTI_41\t41\tReady for Dev\nPVTI_40\t40\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
echo "$open_dep" > "$FAKE_GH_DIR/blocked-by-41"
run_dispatch
out="$(launched)"
assert_contains "$out" "/sf:develop 40"
not_started "AC-1 open dependency" 41
[ -z "$(touched 41)" ] && pass "AC-1 the waiting card gets no label and no move" || fail "AC-1 gh touched #41: $(touched 41)"
case "$(cat "$FAKE_GH_DIR/items.tsv")" in *"PVTI_41"*"Ready for Dev"*) pass "AC-1 the card stays in Ready for Dev" ;; *) fail "AC-1 the card left the queue" ;; esac
[ "$(deps_json 'd["41"]["read"]')" = True ] && pass "AC-8 deps.json says the read of #41 worked" || fail "AC-8 deps.json read for #41: $(deps_json 'd["41"]["read"]')"
[ "$(deps_json '[(x["n"], x["state"]) for x in d["41"]["deps"]]')" = "[(162, 'open')]" ] && pass "AC-8 deps.json holds the open dependency #162" || fail "AC-8 deps.json deps for #41: $(deps_json 'd["41"]["deps"]')"

# AC-1: an orphan (left in Coding with no run) with an open dependency is not resumed either
setup
printf 'PVTI_60\t60\tCoding\n' > "$FAKE_GH_DIR/items.tsv"
echo "$open_dep" > "$FAKE_GH_DIR/blocked-by-60"
run_dispatch
not_started "AC-1 orphan with an open dependency" 60
[ -z "$(touched 60)" ] && pass "AC-1 the waiting orphan gets no label" || fail "AC-1 gh touched #60: $(touched 60)"

# AC-2: the last open dependency closes, the next cycle starts the card with no owner action
setup
printf 'PVTI_41\t41\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
echo "$open_dep" > "$FAKE_GH_DIR/blocked-by-41"
run_dispatch
not_started "AC-2 first cycle, dependency open" 41
echo '[{"number":162,"title":"The base","state":"closed"}]' > "$FAKE_GH_DIR/blocked-by-41"
run_dispatch
assert_contains "$(launched)" "/sf:develop 41"

# AC-3 + AC-8 (closed): a dependency closed as "not planned" is closed to the dispatcher
setup
printf 'PVTI_41\t41\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
echo '[{"number":162,"title":"Dropped","state":"closed","state_reason":"not_planned"}]' > "$FAKE_GH_DIR/blocked-by-41"
run_dispatch
assert_contains "$(launched)" "/sf:develop 41"
[ "$(deps_json '[(x["n"], x["state"]) for x in d["41"]["deps"]]')" = "[(162, 'closed')]" ] && pass "AC-3 deps.json records the not-planned dependency as closed" || fail "AC-3 deps.json deps for #41: $(deps_json 'd["41"]["deps"]')"

# AC-6: the read is REST (gh api repos/.../issues/<n>/dependencies/blocked_by), one call per candidate per cycle
setup
printf 'PVTI_41\t41\tReady for Dev\nPVTI_40\t40\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
echo "$open_dep" > "$FAKE_GH_DIR/blocked-by-41"
run_dispatch
[ "$(dep_calls 41)" = 1 ] && pass "AC-6 one dependency read for the blocked candidate" || fail "AC-6 reads for #41: $(dep_calls 41)"
[ "$(dep_calls 40)" = 1 ] && pass "AC-6 one dependency read for the started candidate" || fail "AC-6 reads for #40: $(dep_calls 40)"
case "$(cat "$FAKE_GH_DIR/dep-calls" 2>/dev/null)" in "api repos/acme/shop/issues/"*) pass "AC-6 the read is gh api (REST) on project.repo" ;; *) fail "AC-6 the read was: $(cat "$FAKE_GH_DIR/dep-calls" 2>/dev/null)" ;; esac
case "$(grep -h dependencies "$FAKE_GH_DIR/calls" 2>/dev/null)" in *graphql*) fail "AC-6 the dependency read used GraphQL" ;; *) pass "AC-6 the dependency read did not use GraphQL" ;; esac

# AC-6 + AC-8 (error): the API fails; the card is not started and not blocked
setup
printf 'PVTI_41\t41\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
touch "$FAKE_GH_DIR/fail-deps"
run_dispatch
not_started "AC-6 API error" 41
[ -z "$(touched 41)" ] && pass "AC-6 an API error does not block the card" || fail "AC-6 gh touched #41 after an error: $(touched 41)"
[ "$(deps_json 'd["41"]["read"]')" = False ] && pass "AC-6 deps.json marks the failed read (read false)" || fail "AC-6 deps.json read for #41: $(deps_json 'd["41"]["read"]')"
rm "$FAKE_GH_DIR/fail-deps"
run_dispatch
assert_contains "$(launched)" "/sf:develop 41"  # once GitHub answers it starts

# AC-6: a body that is not a JSON array is an error too
setup
printf 'PVTI_41\t41\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
echo '{"message":"Not Found"}' > "$FAKE_GH_DIR/blocked-by-41"
run_dispatch
not_started "AC-6 a body that is not an array" 41

# AC-7: refinement starts with open dependencies, and does not even read them
setup
printf 'PVTI_51\t51\tReady for Refinement\n' > "$FAKE_GH_DIR/items.tsv"
echo "$open_dep" > "$FAKE_GH_DIR/blocked-by-51"
run_dispatch
assert_contains "$(launched)" "/sf:refine 51"
[ "$(dep_calls 51)" = 0 ] && pass "AC-7 refine does not read dependencies" || fail "AC-7 refine read the dependencies of #51"
finish
