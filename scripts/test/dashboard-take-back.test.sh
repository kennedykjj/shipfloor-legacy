#!/usr/bin/env bash
# A card blocked for the owner taken back (#127): POST take-back against the real dashboard.py with a fake gh.
#   AC-2  from Coding and Validation: Ready for Dev, Ready for Refinement, Inbox; from anywhere else only the last two;
#         every other target is refused and moves nothing
#   AC-3  a comment is posted before the move; none is posted without one
#   AC-4  to the Inbox: the card's open pull request is closed with no --delete-branch, before the move; a failed close moves nothing
#   AC-5  to Ready for Dev or Ready for Refinement: no pull request is closed
#   AC-6  after the move the block labels come off and the next overview shows no block
#   AC-7  a card blocked by infrastructure, a card with a live run and a card that is not blocked are refused (409)
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
H_TOK="X-Shipfloor-Token: $tok"
post() { curl -s -o "$FAKE_GH_DIR/resp" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d "$2" "$base/api/card/shop/$1"; }
edits() { if [ -f "$FAKE_GH_DIR/edits" ]; then grep -c 'item-edit' "$FAKE_GH_DIR/edits" | tr -d '\r'; else echo 0; fi; }
fresh() { rm -f "$FAKE_GH_DIR/edits" "$FAKE_GH_DIR/comments" "$FAKE_GH_DIR/positions" "$FAKE_GH_DIR/pr-closed" "$FAKE_GH_DIR/prs" \
  "$FAKE_GH_DIR"/fail-* "$FAKE_GH_DIR"/labels-*; : > "$FAKE_GH_DIR/calls"; }
opt() { local i=0 c; for c in "Inbox" "Ready for Refinement" "Technical Refinement" "Spec Review" "Ready for Dev" "Coding" "Validation" "Staged" "Ready for Prod" "Done"; do
  i=$((i+1)); [ "$c" = "$1" ] && { echo "opt$i"; return; }; done; }
COLS=("Inbox" "Ready for Refinement" "Technical Refinement" "Spec Review" "Ready for Dev" "Coding" "Validation" "Staged" "Ready for Prod" "Done")
# card 9 in <column>, alone on the board, blocked for the owner
blocked() { printf 'PVTI_9\t9\t%s\n' "$1" > "$FAKE_GH_DIR/items.tsv"; echo blocked > "$FAKE_GH_DIR/labels-9"; }
body() { printf '{"to":"%s","text":"%s"}' "$1" "${2:-}"; }
line() { grep -n "$1" "$FAKE_GH_DIR/calls" | head -n 1 | cut -d: -f1; }

# AC-2: the table, column by column
bad=""; n=0
for from in "${COLS[@]}"; do
  case "$from" in Coding|Validation) allowed="|Inbox|Ready for Refinement|Ready for Dev|" ;; *) allowed="|Inbox|Ready for Refinement|" ;; esac
  for to in "Inbox" "Ready for Refinement" "Ready for Dev"; do
    fresh; blocked "$from"; n=$((n+1))
    got="$(post 9/take-back "$(body "$to")")"
    if [ "$to" != "$from" ] && [[ "$allowed" == *"|$to|"* ]]; then
      [ "$got" = 200 ] && grep -q "PVTI_9.*$(opt "$to")\$" "$FAKE_GH_DIR/edits" 2>/dev/null || bad="$bad $from→$to=$got(want 200)"
    else
      [ "$got" = 409 ] && [ "$(edits)" = 0 ] || bad="$bad $from→$to=$got(want 409)"
    fi
  done
done
[ -z "$bad" ] && pass "AC-2 the $n blocked moves follow the table: Coding and Validation reach three columns, the rest two" || fail "AC-2 wrong answers:$bad"
fresh; blocked "Validation"
got="$(post 9/take-back "$(body "Coding")")"
[ "$got" = 400 ] && [ "$(edits)" = 0 ] && pass "AC-2 a target outside the three columns is a 400 and moves nothing" || fail "AC-2 to Coding answered $got"
got="$(post 9/take-back '{"to":["Inbox"]}')"
[ "$got" = 400 ] && pass "AC-2 a target that is not a column name is a 400" || fail "AC-2 a list as the target answered $got"

# AC-3: with a comment it is posted before the move; without one nothing is posted
fresh; blocked "Validation"
got="$(post 9/take-back "$(body "Ready for Dev" "the spec was right, the code was not")")"
[ "$got" = 200 ] && grep -q "the spec was right" "$FAKE_GH_DIR/comments" 2>/dev/null && pass "AC-3 a comment is posted on the issue" || fail "AC-3 with a comment answered $got"
c="$(line 'issue comment')" e="$(line 'item-edit')"
[ -n "$c" ] && [ -n "$e" ] && [ "$c" -lt "$e" ] && pass "AC-3 the comment goes before the move" || fail "AC-3 the comment did not go before the move"
grep -q '"commented": true' "$FAKE_GH_DIR/resp" && pass "AC-3 the answer says it commented" || fail "AC-3 the answer was $(cat "$FAKE_GH_DIR/resp")"
fresh; blocked "Validation"
got="$(post 9/take-back "$(body "Ready for Dev" "   ")")"
[ "$got" = 200 ] && [ ! -s "$FAKE_GH_DIR/comments" ] && [ "$(edits)" = 1 ] && pass "AC-3 a blank comment moves the card and posts nothing" || fail "AC-3 a blank comment answered $got"
fresh; blocked "Validation"; touch "$FAKE_GH_DIR/fail-comment"
got="$(post 9/take-back "$(body "Ready for Dev" "x")")"
[ "$got" = 502 ] && [ "$(edits)" = 0 ] && ! grep -q 'labels/blocked' "$FAKE_GH_DIR/calls" && pass "AC-3 a failed comment moves nothing and keeps the block" || fail "AC-3 a failed comment answered $got"

# AC-4: to the Inbox, the card's open pull request is closed (branch kept) before the move
prs='[{"number":41,"headRefName":"feat/90-other"},{"number":42,"headRefName":"feat/9-the-card"}]'
fresh; blocked "Validation"; printf '%s' "$prs" > "$FAKE_GH_DIR/prs"
got="$(post 9/take-back "$(body "Inbox")")"
[ "$got" = 200 ] && grep -q '^pr close 42 ' "$FAKE_GH_DIR/pr-closed" 2>/dev/null && pass "AC-4 to the Inbox the card's pull request is closed" || fail "AC-4 to the Inbox answered $got (closed: $(cat "$FAKE_GH_DIR/pr-closed" 2>/dev/null))"
[ "$(grep -c . "$FAKE_GH_DIR/pr-closed" | tr -d '\r')" = 1 ] && pass "AC-4 another card's pull request (feat/90-…) stays open" || fail "AC-4 closed: $(cat "$FAKE_GH_DIR/pr-closed")"
! grep -q -- '--delete-branch' "$FAKE_GH_DIR/pr-closed" && pass "AC-4 the branch is kept: no --delete-branch" || fail "AC-4 the close deletes the branch"
c="$(line 'pr close')" e="$(line 'item-edit')"
[ -n "$c" ] && [ -n "$e" ] && [ "$c" -lt "$e" ] && pass "AC-4 the pull request is closed before the move" || fail "AC-4 the close did not go before the move"
grep -q '"pr_closed": 42' "$FAKE_GH_DIR/resp" && pass "AC-4 the answer names the closed pull request" || fail "AC-4 the answer was $(cat "$FAKE_GH_DIR/resp")"
fresh; blocked "Validation"; printf '%s' "$prs" > "$FAKE_GH_DIR/prs"; touch "$FAKE_GH_DIR/fail-pr-close"
got="$(post 9/take-back "$(body "Inbox")")"
[ "$got" = 502 ] && [ "$(edits)" = 0 ] && ! grep -q 'labels/blocked' "$FAKE_GH_DIR/calls" && pass "AC-4 a failed close moves nothing and keeps the block" || fail "AC-4 a failed close answered $got"
fresh; blocked "Technical Refinement"
got="$(post 9/take-back "$(body "Inbox")")"
[ "$got" = 200 ] && grep -q '"pr_closed": null' "$FAKE_GH_DIR/resp" && pass "AC-4 no open pull request is not an error" || fail "AC-4 with no pull request answered $got"

# AC-5: to Ready for Dev or Ready for Refinement, the pull request stays open
for to in "Ready for Dev" "Ready for Refinement"; do
  fresh; blocked "Coding"; printf '%s' "$prs" > "$FAKE_GH_DIR/prs"
  got="$(post 9/take-back "$(body "$to")")"
  [ "$got" = 200 ] && ! grep -q '^pr ' "$FAKE_GH_DIR/calls" && pass "AC-5 to $to the pull request is not touched" || fail "AC-5 to $to answered $got"
done

# AC-6: the block comes off after the move, and the overview shows the card unblocked at once
fresh; blocked "Validation"
printf '9\tValidation\n' > "$P/board.tsv"; printf '[{"number":9}]' > "$FAKE_GH_DIR/label-blocked"; printf '[]' > "$FAKE_GH_DIR/label-blocked-infra"
printf '9\tNine\n' > "$FAKE_GH_DIR/titles.tsv"
ov() { curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; d=json.load(sys.stdin); c=next(c for c in d["projects"][0]["cards"] if c["issue"]==9); print(c["column"], c["blocked"], c["lock"])' | tr -d '\r'; }
before="$(ov)"
[ "$before" = "Validation owner blocked" ] && pass "AC-6 before: the overview shows the card blocked" || fail "AC-6 before: $before"
got="$(post 9/take-back "$(body "Ready for Refinement")")"
d="$(grep -n 'labels/blocked$' "$FAKE_GH_DIR/calls" | head -n 1 | cut -d: -f1)" e="$(line 'item-edit')"
[ "$got" = 200 ] && [ -n "$d" ] && [ "$d" -gt "$e" ] && grep -q 'labels/blocked:infra' "$FAKE_GH_DIR/calls" && pass "AC-6 both block labels come off, after the move" || fail "AC-6 the labels: answered $got, calls: $(cat "$FAKE_GH_DIR/calls")"
printf '[]' > "$FAKE_GH_DIR/label-blocked"  # GitHub now has no blocked label on #9
after="$(ov)"
[ "$after" = "Ready for Refinement None None" ] && pass "AC-6 after: the overview shows the card in its new column, not blocked" || fail "AC-6 after: $after"
grep -q '"unblocked": true' "$FAKE_GH_DIR/resp" && pass "AC-6 the answer says unblocked" || fail "AC-6 the answer was $(cat "$FAKE_GH_DIR/resp")"
rm -f "$FAKE_GH_DIR/label-blocked" "$FAKE_GH_DIR/label-blocked-infra" "$FAKE_GH_DIR/titles.tsv" "$P/board.tsv"

# AC-7: blocked by infrastructure, a live run, not blocked: refused, nothing moves
fresh; printf 'PVTI_9\t9\tValidation\n' > "$FAKE_GH_DIR/items.tsv"; printf 'blocked:infra\nblocked\n' > "$FAKE_GH_DIR/labels-9"
got="$(post 9/take-back "$(body "Inbox" "x")")"
[ "$got" = 409 ] && grep -q '"locked": "infra"' "$FAKE_GH_DIR/resp" && pass "AC-7 a card blocked by infrastructure is refused (409, infra)" || fail "AC-7 infra answered $got: $(cat "$FAKE_GH_DIR/resp")"
[ ! -s "$FAKE_GH_DIR/comments" ] && [ "$(edits)" = 0 ] && pass "AC-7 the refused infra card posts and moves nothing" || fail "AC-7 the refused infra card did something"
fresh; blocked "Validation"; mkdir -p "$P/locks/validate-9.lock"; echo "1 $(date +%s) 26" > "$P/locks/validate-9.lock/info"
got="$(post 9/take-back "$(body "Inbox")")"
[ "$got" = 409 ] && grep -q '"locked": "run"' "$FAKE_GH_DIR/resp" && pass "AC-7 a card with a live run is refused (409, run)" || fail "AC-7 a live run answered $got"
rm -rf "$P/locks/validate-9.lock"
fresh; printf 'PVTI_9\t9\tValidation\n' > "$FAKE_GH_DIR/items.tsv"
got="$(post 9/take-back "$(body "Inbox")")"
[ "$got" = 409 ] && [ "$(edits)" = 0 ] && pass "AC-7 a card that is not blocked is refused (409)" || fail "AC-7 not blocked answered $got"
fresh; printf 'PVTI_8\t8\tValidation\n' > "$FAKE_GH_DIR/items.tsv"
got="$(post 9/take-back "$(body "Inbox")")"
[ "$got" = 409 ] && pass "AC-7 a card not on the board is refused (409)" || fail "AC-7 not on the board answered $got"

# the overview carries the table the page mirrors
tb="$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; t=json.load(sys.stdin)["take_back"]; print(sorted((f, tuple(v)) for f, v in t.items()))' | tr -d '\r')"
[ "$tb" = "[('*', ('Inbox', 'Ready for Refinement')), ('Coding', ('Inbox', 'Ready for Refinement', 'Ready for Dev')), ('Validation', ('Inbox', 'Ready for Refinement', 'Ready for Dev'))]" ] \
  && pass "AC-2 the overview's take_back is the server's table" || fail "AC-2 the overview's take_back: $tb"
finish
