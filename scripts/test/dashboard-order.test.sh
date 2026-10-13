#!/usr/bin/env bash
# The owner orders the queues (#128): the server side with a fake gh, and dashboard.html read as text. The gestures (drag,
# M and the arrows, Undo in the toast) are checked by hand in review.
#   AC-1  the overview gives position 1, 2, 3 in board order in Inbox, Ready for Refinement and Ready for Dev, and names them
#   AC-2  reorder sends the mutation with the right afterId (first, middle, end) and the next overview has the new order
#   AC-5  the page holds a reorder for 5 s and sends it on pagehide
#   AC-6  a locked card is a 423, a card of another column a 403, a bad before a 400: no write
#   AC-7  a stale column or before is a 409 that names the card that left: no write
#   AC-9  M1 to M5 put the card after the target column's last card before its Status changes; a failed write moves nothing
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
printf '[]' > "$FAKE_GH_DIR/label-blocked-infra"; printf '[]' > "$FAKE_GH_DIR/label-blocked"
export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
H_TOK="X-Shipfloor-Token: $tok"
post() { curl -s -o "$FAKE_GH_DIR/resp" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d "$2" "$base/api/card/shop/$1"; }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1: got $2, want $3"; }
fresh() { rm -f "$FAKE_GH_DIR/edits" "$FAKE_GH_DIR/comments" "$FAKE_GH_DIR/positions" "$FAKE_GH_DIR/fail-position" "$FAKE_GH_DIR"/labels-*; : > "$FAKE_GH_DIR/calls"; }
writes() { if [ -f "$FAKE_GH_DIR/positions" ]; then grep -c . "$FAKE_GH_DIR/positions" | tr -d '\r'; else echo 0; fi; }
lastpos() { tail -n 1 "$FAKE_GH_DIR/positions" 2>/dev/null | tr -d '\r'; }
order() { awk -F'\t' -v c="$1" '$3 == c {printf "%s ", $2}' "$FAKE_GH_DIR/items.tsv"; }
# the column's cards as the overview lists them, with their positions: "n:pos n:pos ..."
ov_order() {
  curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; c=sys.argv[1]; print(" ".join("%s:%s" % (x["issue"], x["position"]) for x in json.load(sys.stdin)["projects"][0]["cards"] if x["column"]==c))' "$1" | tr -d '\r'
}

# AC-1: positions in board order in the three ordered columns; the overview names them
printf 'PVTI_20\t20\tInbox\nPVTI_1\t1\tReady for Dev\nPVTI_21\t21\tInbox\nPVTI_8\t8\tCoding\nPVTI_2\t2\tReady for Dev\nPVTI_30\t30\tReady for Refinement\nPVTI_3\t3\tReady for Dev\nPVTI_31\t31\tReady for Refinement\n' > "$FAKE_GH_DIR/items.tsv"
awk -F'\t' '{print $2"\t"$3}' "$FAKE_GH_DIR/items.tsv" > "$P/board.tsv"
eq "AC-1 Inbox lists its cards in board order with positions" "$(ov_order Inbox)" "20:1 21:2"
eq "AC-1 Ready for Refinement lists its cards in board order with positions" "$(ov_order "Ready for Refinement")" "30:1 31:2"
eq "AC-1 Ready for Dev lists its cards in board order with positions" "$(ov_order "Ready for Dev")" "1:1 2:2 3:3"
eq "AC-1 a card of another column has no position" "$(ov_order Coding)" "8:None"
eq "AC-1 the overview names the ordered columns" "$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; print(json.load(sys.stdin)["ordered"])' | tr -d '\r')" "['Inbox', 'Ready for Refinement', 'Ready for Dev']"

# AC-2: before a card in the middle of the project, at the end of the column, first in the project, and a no-op
fresh
printf 'PVTI_1\t1\tReady for Dev\nPVTI_8\t8\tCoding\nPVTI_2\t2\tReady for Dev\nPVTI_3\t3\tReady for Dev\nPVTI_5\t5\tReady for Refinement\nPVTI_6\t6\tReady for Refinement\n' > "$FAKE_GH_DIR/items.tsv"
got="$(post 3/reorder '{"column":"Ready for Dev","before":2}')"
eq "AC-2 #3 before #2 answers 200" "$got" 200
grep -q '"position": 2' "$FAKE_GH_DIR/resp" && pass "AC-2 the answer gives the new position" || fail "AC-2 the answer was $(cat "$FAKE_GH_DIR/resp")"
eq "AC-2 #3 before #2 goes after the item right before #2" "$(lastpos)" "PVTI_3 after PVTI_8"
eq "AC-2 the board has the new order" "$(order "Ready for Dev")" "1 3 2 "
eq "AC-2 the next overview has the new order at once" "$(ov_order "Ready for Dev")" "1:1 3:2 2:3"
got="$(post 1/reorder '{"column":"Ready for Dev","before":null}')"
eq "AC-2 #1 to the end answers 200" "$got" 200
eq "AC-2 to the end goes after the column's last card" "$(lastpos)" "PVTI_1 after PVTI_2"
eq "AC-2 the next overview has #1 last" "$(ov_order "Ready for Dev")" "3:1 2:2 1:3"
got="$(post 6/reorder '{"column":"Ready for Refinement","before":5}')"
eq "AC-2 #6 before #5 answers 200" "$got" 200
eq "AC-2 before the project's first item there, it goes after the item before" "$(lastpos)" "PVTI_6 after PVTI_1"
printf 'PVTI_5\t5\tReady for Refinement\nPVTI_6\t6\tReady for Refinement\nPVTI_7\t7\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
got="$(post 6/reorder '{"column":"Ready for Refinement","before":5}')"
eq "AC-2 before the project's first item: no afterId, first in the project" "$(lastpos)" "PVTI_6 after -"
n="$(writes)"; got="$(post 6/reorder '{"column":"Ready for Refinement","before":5}')"
[ "$got" = 200 ] && [ "$(writes)" = "$n" ] && pass "AC-2 a card already in that place is a 200 with no write" || fail "AC-2 a no-op answered $got with $(( $(writes) - n )) writes"
grep -q '"position": 1' "$FAKE_GH_DIR/resp" && pass "AC-2 the no-op still says the position" || fail "AC-2 the no-op answered $(cat "$FAKE_GH_DIR/resp")"

# AC-6: locked, another column, a bad before: refused with no write
fresh
printf 'PVTI_1\t1\tReady for Dev\nPVTI_2\t2\tReady for Dev\nPVTI_4\t4\tSpec Review\nPVTI_9\t9\tReady for Prod\n' > "$FAKE_GH_DIR/items.tsv"
mkdir -p "$P/locks/develop-2.lock"; echo "1 $(date +%s) 26" > "$P/locks/develop-2.lock/info"
got="$(post 2/reorder '{"column":"Ready for Dev","before":1}')"
[ "$got" = 423 ] && grep -q '"locked": "run"' "$FAKE_GH_DIR/resp" && pass "AC-6 a card with a live run is a 423" || fail "AC-6 a locked reorder answered $got"
rm -rf "$P/locks/develop-2.lock"; echo blocked > "$FAKE_GH_DIR/labels-2"
got="$(post 2/reorder '{"column":"Ready for Dev","before":1}')"; eq "AC-6 a blocked card is a 423" "$got" 423
rm -f "$FAKE_GH_DIR/labels-2"
got="$(post 1/reorder '{"column":"Ready for Dev","before":2}')"; eq "AC-6 the same card unlocked is reordered" "$got" 200
fresh
got="$(post 4/reorder '{"column":"Spec Review","before":null}')"; eq "AC-6 a Spec Review card is a 403" "$got" 403
got="$(post 9/reorder '{"column":"Ready for Prod","before":null}')"; eq "AC-6 a Ready for Prod card is a 403" "$got" 403
got="$(post 1/reorder '{"column":"Ready for Dev","before":1}')"; eq "AC-6 before itself is a 400" "$got" 400
got="$(post 1/reorder '{"column":"Ready for Dev","before":"2"}')"; eq "AC-6 a before that is not a number is a 400" "$got" 400
got="$(post 1/reorder '{"column":"Ready for Dev","before":true}')"; eq "AC-6 a boolean before is a 400" "$got" 400
eq "AC-6 no refused reorder wrote anything" "$(writes)" 0

# AC-7: the card or the card it goes before left the column
got="$(post 4/reorder '{"column":"Ready for Dev","before":1}')"
[ "$got" = 409 ] && grep -q '"gone": 4' "$FAKE_GH_DIR/resp" && pass "AC-7 a card no longer in the column is a 409 naming it" || fail "AC-7 a stale card answered $got: $(cat "$FAKE_GH_DIR/resp")"
got="$(post 2/reorder '{"column":"Ready for Dev","before":4}')"
[ "$got" = 409 ] && grep -q '"gone": 4' "$FAKE_GH_DIR/resp" && pass "AC-7 a before no longer in the column is a 409 naming it" || fail "AC-7 a stale before answered $got: $(cat "$FAKE_GH_DIR/resp")"
eq "AC-7 no stale reorder wrote anything" "$(writes)" 0

# AC-9: a card the owner moves into an ordered column goes after its last card, before the Status changes
for m in "Inbox|Ready for Refinement|PVTI_11|" "Ready for Refinement|Inbox|PVTI_10|" "Spec Review|Ready for Dev|PVTI_12|" "Spec Review|Ready for Refinement|PVTI_11|why" "Ready for Dev|Ready for Refinement|PVTI_11|why"; do
  IFS='|' read -r from to last text <<< "$m"; fresh
  printf 'PVTI_9\t9\t%s\nPVTI_10\t10\tInbox\nPVTI_11\t11\tReady for Refinement\nPVTI_12\t12\tReady for Dev\nPVTI_13\t13\tCoding\n' "$from" > "$FAKE_GH_DIR/items.tsv"
  got="$(post 9/move "{\"column\":\"$from\",\"to\":\"$to\",\"text\":\"$text\"}")"
  eq "AC-9 $from → $to answers 200" "$got" 200
  eq "AC-9 $from → $to puts the card after the last card of $to" "$(lastpos)" "PVTI_9 after $last"
  p="$(grep -n 'updateProjectV2ItemPosition' "$FAKE_GH_DIR/calls" | head -n 1 | cut -d: -f1)"; e="$(grep -n 'item-edit' "$FAKE_GH_DIR/calls" | head -n 1 | cut -d: -f1)"
  [ -n "$p" ] && [ -n "$e" ] && [ "$p" -lt "$e" ] && pass "AC-9 $from → $to: the place is written before the Status" || fail "AC-9 $from → $to: the place was not written before the Status"
done
eq "AC-9 the next overview shows the card last of its new column" "$(ov_order "Ready for Refinement")" "11:1 9:2"
fresh; printf 'PVTI_9\t9\tSpec Review\nPVTI_12\t12\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"; touch "$FAKE_GH_DIR/fail-position"
got="$(post 9/move '{"column":"Spec Review","to":"Ready for Dev"}')"
[ "$got" = 502 ] && [ ! -f "$FAKE_GH_DIR/edits" ] && pass "AC-9 a failed place write is a 502 and moves nothing" || fail "AC-9 a failed place write answered $got (edits: $(cat "$FAKE_GH_DIR/edits" 2>/dev/null))"
fresh; printf 'PVTI_9\t9\tInbox\nPVTI_12\t12\tReady for Dev\n' > "$FAKE_GH_DIR/items.tsv"
got="$(post 9/move '{"column":"Inbox","to":"Ready for Refinement"}')"
[ "$got" = 200 ] && [ "$(writes)" = 0 ] && pass "AC-9 into an empty column: no place write" || fail "AC-9 into an empty column answered $got with $(writes) writes"
fresh; printf 'PVTI_9\t9\tStaged\nPVTI_14\t14\tReady for Prod\n' > "$FAKE_GH_DIR/items.tsv"
got="$(post 9/move '{"column":"Staged","to":"Ready for Prod"}')"
[ "$got" = 200 ] && [ "$(writes)" = 0 ] && pass "AC-9 into Ready for Prod, not ordered by the owner: no place write" || fail "AC-9 into Ready for Prod answered $got with $(writes) writes"

# AC-5 and AC-1, page read as text
page="$(cat "$FACTORY_DIR/dashboard.html")"
case "$page" in *'/reorder`'*) pass "AC-5 page: a pending reorder is sent to reorder" ;; *) fail "AC-5 page: no request to reorder" ;; esac
case "$page" in *"e.reorder"*) pass "AC-5 page: sendPending knows a reorder" ;; *) fail "AC-5 page: sendPending does not send a reorder" ;; esac
case "$page" in *"overview?.ordered"*|*"overview.ordered"*) pass "AC-1 page: the ordered columns come from the overview" ;; *) fail "AC-1 page: the page does not read the overview's ordered" ;; esac
CAT="$FACTORY_DIR/lang/dashboard.pt-BR.json"
for s in "Posição {i} de {n}" "Subir" "Descer" "Deixar aqui" " agora é o {i} de {of} em " " voltou para {i} de {of} em " " não foi reordenado: " "ele não está mais em " "Segurando o #{n}, {i} de {of} em " \
  "seta para cima ou para baixo para reordenar, Enter para deixar no lugar, Esc para soltar." "#{n}, {i} de {of}."; do  # values by name since #122
  grep -qF -- "$s" "$CAT" && pass "AC-1 pt-BR catalog: $s" || fail "AC-1 pt-BR catalog lacks: $s"
done
finish
