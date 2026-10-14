#!/usr/bin/env bash
# suite: integration
# The dashboard shows a card's dependencies (#202) from the dispatcher's record, <project home>/deps.json; it keeps no state
# of its own and makes no dependency call.
#   AC-4  a card with dependencies: each one's number, title and state (its board column, or "closed", or "open" when off the
#         board); the page has the "Depends on" block; the four new messages exist in all 12 catalogs
#   AC-3  a dependency closed as "not planned" shows as closed (the record says "closed" whatever the reason)
#   AC-5  a queued card waiting only on dependencies has its tile line "Waiting on {list}"
#   AC-6  a card whose dependencies the dispatcher could not read says so (deps_unread) instead of listing
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
export FAKE_GH_DIR="$(mktemp -d)"
printf '41\tForty-one\n42\tForty-two\n43\tForty-three\n162\tThe base\n' > "$FAKE_GH_DIR/titles.tsv"
srv=""; trap 'kill $srv 2>/dev/null' EXIT

# the board: 41 and 42 and 43 queued, 162 being coded; the record of what the dispatcher read
printf '41\tReady for Dev\n42\tReady for Dev\n43\tReady for Dev\n162\tCoding\n' > "$P/board.tsv"
cat > "$P/deps.json" <<'EOF'
{"41": {"read": true, "deps": [
   {"n": 162, "title": "The base", "state": "open"},
   {"n": 163, "title": "Dropped for good", "state": "closed"},
   {"n": 170, "title": "Off the board", "state": "open"}]},
 "42": {"read": false, "deps": []},
 "43": {"read": true, "deps": []}}
EOF
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$C/out" 2>&1 &
srv=$!
for _ in $(seq 1 50); do grep -qs 'http://' "$C/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$C/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
TOK="X-Shipfloor-Token: $tok"
overview() { curl -s -H "$TOK" "$base/api/overview"; }
# card_expr <n> <python expr on c>: the overview's card <n>
card_expr() { overview | $PY -c 'import json,sys; n=int(sys.argv[1]); c=next((c for c in json.load(sys.stdin)["projects"][0]["cards"] if c["issue"] == n), {}); print(eval(sys.argv[2]))' "$1" "$2" 2>&1 | tr -d '\r'; }
# the state of dependency <d> of card 41, whatever the key that holds the number or the state
dep_state() { card_expr 41 "next(((x.get('state') or x.get('column')) for x in c.get('deps', []) if x.get('n', x.get('issue')) == $1), '<none>')"; }
dep_title() { card_expr 41 "next((x.get('title') for x in c.get('deps', []) if x.get('n', x.get('issue')) == $1), '<none>')"; }

# AC-4: every dependency, with its number, title and state
[ "$(card_expr 41 'sorted(x.get("n", x.get("issue")) for x in c.get("deps", []))')" = "[162, 163, 170]" ] && pass "AC-4 card 41 lists its three dependencies" || fail "AC-4 card 41 deps: $(card_expr 41 'c.get("deps", "<no deps key>")')"
[ "$(dep_state 162)" = "Coding" ] && pass "AC-4 an open dependency on the board shows its column" || fail "AC-4 #162 state: $(dep_state 162)"
[ "$(dep_state 170)" = "open" ] && pass "AC-4 an open dependency off the board shows as open" || fail "AC-4 #170 state: $(dep_state 170)"
[ "$(dep_title 162)" = "The base" ] && pass "AC-4 the dependency carries its title" || fail "AC-4 #162 title: $(dep_title 162)"
[ "$(card_expr 41 'c.get("deps_unread")')" = False ] && pass "AC-4 a card whose dependencies were read is not unread" || fail "AC-4 deps_unread for #41: $(card_expr 41 'c.get("deps_unread")')"

# AC-3: closed (merged or not planned) reads as closed
[ "$(dep_state 163)" = "closed" ] && pass "AC-3 a closed dependency shows as closed" || fail "AC-3 #163 state: $(dep_state 163)"

# a card with no dependency looks as today
[ "$(card_expr 43 'c.get("deps", [])')" = "[]" ] && pass "AC-4 a card with no dependency has none listed" || fail "AC-4 card 43 deps: $(card_expr 43 'c.get("deps")')"
[ "$(card_expr 43 'c.get("deps_unread")')" = False ] && pass "AC-4 a card with no dependency is not unread" || fail "AC-4 deps_unread for #43: $(card_expr 43 'c.get("deps_unread")')"

# AC-6: the failed read is said, not hidden
[ "$(card_expr 42 'c.get("deps_unread")')" = True ] && pass "AC-6 a card whose dependencies were not read is flagged deps_unread" || fail "AC-6 deps_unread for #42: $(card_expr 42 'c.get("deps_unread")')"

# the dashboard asks GitHub nothing about dependencies: it reads the record
if [ -f "$FAKE_GH_DIR/dep-calls" ]; then fail "AC-4 the dashboard called the dependency API"; else pass "AC-4 the dashboard makes no dependency call"; fi

# AC-4 / AC-5 / AC-6: the page has the block and the lines, by message key
page="$(cat "$FACTORY_DIR/dashboard.html")"
for k in dep.h dep.closed dep.open why.deps dep.unread; do
  case "$page" in *"t(\"$k\""*|*"t('$k'"*|*"\"$k\""*) pass "AC-4 the page uses $k" ;; *) fail "AC-4 the page does not use $k" ;; esac
done
case "$page" in *'aria-label'*'Depends on'*|*'aria-label="${'*'dep.h'*) pass "AC-4 the drawer list is labelled 'Depends on'" ;; *) fail "AC-4 no aria-label from dep.h on the dependency list" ;; esac

# the English copy, and every catalog has the keys
[ "$(en_msg dep.h)" = "Depends on" ] && pass "AC-4 dep.h is 'Depends on'" || fail "AC-4 dep.h is: $(en_msg dep.h)"
[ "$(en_msg dep.closed)" = "closed" ] && pass "AC-3 dep.closed is 'closed'" || fail "AC-3 dep.closed is: $(en_msg dep.closed)"
[ "$(en_msg why.deps)" = "Waiting on {list}" ] && pass "AC-5 why.deps is 'Waiting on {list}'" || fail "AC-5 why.deps is: $(en_msg why.deps)"
[ "$(en_msg dep.unread)" = "Dependencies not read; it starts once GitHub answers" ] && pass "AC-6 dep.unread says it starts once GitHub answers" || fail "AC-6 dep.unread is: $(en_msg dep.unread)"
for l in de en es fr it ja ko pt-BR ru tr zh-CN zh-TW; do
  for k in dep.h dep.closed dep.open why.deps dep.unread; do
    [ -n "$(lang_msg "$l" "$k")" ] || fail "AC-4 catalog $l lacks $k"
  done
  case "$(lang_msg "$l" why.deps)" in *"{list}"*) pass "AC-5 catalog $l keeps {list} in why.deps" ;; *) fail "AC-5 catalog $l why.deps has no {list}: $(lang_msg "$l" why.deps)" ;; esac
done
finish
