#!/usr/bin/env bash
# The owner moves cards in the maximized Lifecycle (#125): the server side with a fake gh, and dashboard.html read as text.
# The gestures (drag, M + digit, the note box, Undo in the toast) are checked by hand in review.
#   AC-1  M1, M2, M3 and M6 move at once through move
#   AC-2  M4, M5 and M7 need a note: an empty one is a 400 and moves nothing; a note is posted, then the card moves
#   AC-3  every other pair of the ten columns is a 403 and moves nothing
#   AC-5  a stale column is a 409; the page holds a move for 5 s and sends it on pagehide; comment posts and moves nothing
#   AC-6  a card with a live run, or blocked:infra, is a 423 through move, approve and request-changes; the overview says lock
#   AC-8  the overview carries opened, position and moves; each new string is in the pt-BR catalog
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
fresh() { rm -f "$FAKE_GH_DIR/edits" "$FAKE_GH_DIR/comments" "$FAKE_GH_DIR/positions" "$FAKE_GH_DIR"/labels-*; : > "$FAKE_GH_DIR/calls"; }
# the option id of each column in the fake board, in board order
opt() { local i=0 c; for c in "Inbox" "Ready for Refinement" "Technical Refinement" "Spec Review" "Ready for Dev" "Coding" "Validation" "Staged" "Ready for Prod" "Done"; do
  i=$((i+1)); [ "$c" = "$1" ] && { echo "opt$i"; return; }; done; }
COLS=("Inbox" "Ready for Refinement" "Technical Refinement" "Spec Review" "Ready for Dev" "Coding" "Validation" "Staged" "Ready for Prod" "Done")
# card 9 in <column>, alone on the board
alone() { printf 'PVTI_9\t9\t%s\n' "$1" > "$FAKE_GH_DIR/items.tsv"; }
move_body() { printf '{"column":"%s","to":"%s","text":"%s"}' "$1" "$2" "${3:-}"; }

# AC-1: the four moves that go at once
for m in "Inbox|Ready for Refinement" "Ready for Refinement|Inbox" "Spec Review|Ready for Dev" "Staged|Ready for Prod"; do
  from="${m%|*}" to="${m#*|}"; fresh; alone "$from"
  got="$(post 9/move "$(move_body "$from" "$to")")"
  if [ "$got" = 200 ] && grep -q "PVTI_9.*$(opt "$to")\$" "$FAKE_GH_DIR/edits" 2>/dev/null && [ ! -s "$FAKE_GH_DIR/comments" ]; then
    pass "AC-1 $from → $to moves at once"
  else fail "AC-1 $from → $to answered $got (edits: $(cat "$FAKE_GH_DIR/edits" 2>/dev/null))"; fi
done
grep -q '"moved_to": "Ready for Prod"' "$FAKE_GH_DIR/resp" && pass "AC-1 the answer names where the card went" || fail "AC-1 the answer was $(cat "$FAKE_GH_DIR/resp")"

# AC-2: the three moves that need a note
for m in "Spec Review|Ready for Refinement" "Ready for Dev|Ready for Refinement" "Staged|Coding"; do
  from="${m%|*}" to="${m#*|}"; fresh; alone "$from"
  got="$(post 9/move "$(move_body "$from" "$to" "  ")")"
  [ "$got" = 400 ] && [ "$(edits)" = 0 ] && [ ! -s "$FAKE_GH_DIR/comments" ] && pass "AC-2 $from → $to with an empty note is a 400 and moves nothing" \
    || fail "AC-2 $from → $to with an empty note answered $got ($(edits) moves)"
  got="$(post 9/move "$(move_body "$from" "$to" "do it again")")"
  if [ "$got" = 200 ] && grep -q "do it again" "$FAKE_GH_DIR/comments" 2>/dev/null && grep -q "PVTI_9.*$(opt "$to")\$" "$FAKE_GH_DIR/edits" 2>/dev/null; then
    pass "AC-2 $from → $to with a note posts it and moves the card"
  else fail "AC-2 $from → $to with a note answered $got"; fi
  c="$(grep -n 'issue comment' "$FAKE_GH_DIR/calls" | head -n 1 | cut -d: -f1)"; e="$(grep -n 'item-edit' "$FAKE_GH_DIR/calls" | head -n 1 | cut -d: -f1)"
  [ -n "$c" ] && [ -n "$e" ] && [ "$c" -lt "$e" ] && pass "AC-2 $from → $to: the note goes before the move" || fail "AC-2 $from → $to: the note did not go before the move"
done

# AC-3: every other pair is refused and moves nothing
bad=""; n=0
for from in "${COLS[@]}"; do
  for to in "${COLS[@]}"; do
    case "$from|$to" in "Inbox|Ready for Refinement"|"Ready for Refinement|Inbox"|"Spec Review|Ready for Dev"|"Spec Review|Ready for Refinement"|"Ready for Dev|Ready for Refinement"|"Staged|Ready for Prod"|"Staged|Coding") continue ;; esac
    alone "$from"; n=$((n+1))
    got="$(post 9/move "$(move_body "$from" "$to" "a note")")"; [ "$got" = 403 ] || bad="$bad $from→$to=$got"
  done
done
fresh
[ -z "$bad" ] && pass "AC-3 the $n other pairs are all refused with 403" || fail "AC-3 not refused:$bad"
[ ! -f "$FAKE_GH_DIR/edits" ] && pass "AC-3 no refused pair moved anything" || fail "AC-3 a refused pair moved a card"
alone "Inbox"; got="$(post 9/move '{"column":"Inbox","to":["Ready for Refinement"]}')"
[ "$got" = 403 ] && pass "AC-3 a target that is not a column name is a 403" || fail "AC-3 a list as the target answered $got"

# AC-5: a stale column is refused; comment posts and moves nothing
fresh; alone "Ready for Dev"
got="$(post 9/move "$(move_body "Spec Review" "Ready for Dev")")"
[ "$got" = 409 ] && [ "$(edits)" = 0 ] && pass "AC-5 a move with a stale column is a 409 and moves nothing" || fail "AC-5 a stale move answered $got ($(edits) moves)"
grep -q '"column": "Ready for Dev"' "$FAKE_GH_DIR/resp" && pass "AC-5 the 409 says where the card is now" || fail "AC-5 the 409 was $(cat "$FAKE_GH_DIR/resp")"
got="$(post 9/comment '{"text":"one more thing"}')"
[ "$got" = 200 ] && grep -q "one more thing" "$FAKE_GH_DIR/comments" && [ "$(edits)" = 0 ] && pass "AC-5 comment posts on the issue and moves nothing" || fail "AC-5 comment answered $got"
got="$(post 9/comment '{"text":" "}')"
[ "$got" = 400 ] && pass "AC-5 an empty comment is a 400" || fail "AC-5 an empty comment answered $got"

# AC-6: a live run, a blocked:infra label: refused with 423 through every endpoint that moves
fresh; alone "Spec Review"
mkdir -p "$P/locks/refine-9.lock"; echo "1 $(date +%s) 26" > "$P/locks/refine-9.lock/info"
got="$(post 9/move "$(move_body "Spec Review" "Ready for Dev")")"
[ "$got" = 423 ] && grep -q '"locked": "run"' "$FAKE_GH_DIR/resp" && pass "AC-6 move of a card with a live run is a 423 (run)" || fail "AC-6 move with a live run answered $got: $(cat "$FAKE_GH_DIR/resp")"
got="$(post 9/approve '{"column":"Spec Review"}')"; [ "$got" = 423 ] && pass "AC-6 approve of a card with a live run is a 423" || fail "AC-6 approve with a live run answered $got"
got="$(post 9/request-changes '{"column":"Spec Review","text":"x"}')"; [ "$got" = 423 ] && pass "AC-6 request-changes of a card with a live run is a 423" || fail "AC-6 request-changes with a live run answered $got"
[ ! -s "$FAKE_GH_DIR/comments" ] && pass "AC-6 a locked request-changes posts no note" || fail "AC-6 a locked request-changes posted its note"
rm -rf "$P/locks/refine-9.lock"; echo "blocked:infra" > "$FAKE_GH_DIR/labels-9"
got="$(post 9/move "$(move_body "Spec Review" "Ready for Dev")")"
[ "$got" = 423 ] && grep -q '"locked": "infra"' "$FAKE_GH_DIR/resp" && pass "AC-6 move of a blocked:infra card is a 423 (infra)" || fail "AC-6 move of a blocked:infra card answered $got"
got="$(post 9/approve '{"column":"Spec Review"}')"; [ "$got" = 423 ] && pass "AC-6 approve of a blocked:infra card is a 423" || fail "AC-6 approve of a blocked:infra card answered $got"
[ "$(edits)" = 0 ] && pass "AC-6 no locked card moved" || fail "AC-6 a locked card moved"

# AC-6 and AC-8: the overview says lock, opened, position and the moves table
fresh
printf 'PVTI_1\t1\tReady for Dev\nPVTI_2\t2\tSpec Review\nPVTI_3\t3\tReady for Dev\nPVTI_4\t4\tReady for Prod\nPVTI_5\t5\tCoding\n' > "$FAKE_GH_DIR/items.tsv"
printf '1\tReady for Dev\n2\tSpec Review\n3\tReady for Dev\n4\tReady for Prod\n5\tCoding\n' > "$P/board.tsv"
printf '1\tOne\t2026-10-01T10:00:00Z\n2\tTwo\n3\tThree\n4\tFour\n5\tFive\n' > "$FAKE_GH_DIR/titles.tsv"
printf '[{"number":3}]' > "$FAKE_GH_DIR/label-blocked-infra"; printf '[]' > "$FAKE_GH_DIR/label-blocked"
mkdir -p "$P/locks/develop-5.lock"; echo "1 $(date +%s) 26" > "$P/locks/develop-5.lock/info"
ov="$(curl -s -H "$H_TOK" "$base/api/overview")"
card() { printf '%s' "$ov" | $PY -c 'import json,sys; n=int(sys.argv[1]); c=next(c for c in json.load(sys.stdin)["projects"][0]["cards"] if c["issue"]==n); print(json.dumps(c.get(sys.argv[2], "<missing>")))' "$1" "$2" | tr -d '\r'; }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1: got $2, want $3"; }
eq "AC-6 the overview says lock run for a card with a live run" "$(card 5 lock)" '"run"'
eq "AC-6 the overview says lock infra for a blocked:infra card" "$(card 3 lock)" '"infra"'
eq "AC-6 the overview says lock null for a free card" "$(card 1 lock)" 'null'
eq "AC-8 the overview carries the issue's opened date" "$(card 1 opened)" '"2026-10-01T10:00:00Z"'
eq "AC-8 the first card of Ready for Dev is at position 1" "$(card 1 position)" '1'
eq "AC-8 the second card of Ready for Dev is at position 2" "$(card 3 position)" '2'
eq "AC-8 a Ready for Prod card has its position" "$(card 4 position)" '1'
eq "AC-8 a Spec Review card has no position" "$(card 2 position)" 'null'
moves="$(printf '%s' "$ov" | $PY -c 'import json,sys; m=json.load(sys.stdin)["moves"]; print(sorted((f, t["to"], t["note"]) for f in m for t in m[f]))' | tr -d '\r')"
eq "AC-8 the overview's moves are M1 to M7" "$moves" "[('Inbox', 'Ready for Refinement', False), ('Ready for Dev', 'Ready for Refinement', True), ('Ready for Refinement', 'Inbox', False), ('Spec Review', 'Ready for Dev', False), ('Spec Review', 'Ready for Refinement', True), ('Staged', 'Coding', True), ('Staged', 'Ready for Prod', False)]"
rm -rf "$P/locks/develop-5.lock"

# page, read as text
page="$(cat "$FACTORY_DIR/dashboard.html")"
pagehide="$(printf '%s' "$page" | grep -m1 'addEventListener("pagehide"')"
case "$pagehide" in *sendPending*keepalive*|*sendPending*true*) pass "AC-5 page: pagehide sends what is pending, with keepalive" ;; *) fail "AC-5 page: pagehide does not send the pending moves" ;; esac
case "$page" in *'/move`'*) pass "AC-5 page: a pending move is sent to move" ;; *) fail "AC-5 page: no request to move" ;; esac
case "$page" in *"setTimeout(() => sendPending(k), 5000)"*) pass "AC-5 page: a move waits 5 s before it leaves" ;; *) fail "AC-5 page: a move does not wait 5 s" ;; esac
case "$page" in *"overview?.moves"*|*"overview.moves"*) pass "AC-3 page: what a card accepts comes from the overview's moves" ;; *) fail "AC-3 page: the page does not read the overview's moves" ;; esac

# AC-8: every new string is in the pt-BR catalog, and no entry translates a column or lane name inside them
CAT="$FACTORY_DIR/lang/dashboard.pt-BR.json"
for s in "Só o que eu posso mover" "Nada para você mover agora." "na fila" \
  "travado · {why}" "uma execução está em andamento" "bloqueado por infraestrutura, a fábrica tenta de novo" "Solte para " "Aperte {n} para " "Toque para " \
  "mandar para o refinamento" "tirar da fila" "aprovar a spec" "pedir mudanças" "refinar de novo" "aprovar e publicar" "a fábrica move" "Mover" \
  "Refinar o #{n} de novo" "O que o refinamento deve fazer diferente?" "Refinar de novo" "Comentar no #{n}" "Opcional: um comentário, publicado na issue" "Publicar comentário" \
  " foi para " "O quadro confirma na próxima leitura do dispatcher." "Comentar" " voltou para " "Comentário publicado no #{n}." " não foi movido: " \
  "Segurando o #{n}." "Esc para soltar." " solto. Ele não se moveu." " não pode ser movido: " "Quem move o #{n} é a fábrica."; do  # values by name since #122
  grep -qF -- "$s" "$CAT" && pass "AC-8 pt-BR catalog: $s" || fail "AC-8 pt-BR catalog lacks: $s"
done
if $PY -I -c '
import json, re, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
new = [v for k, v in cat["messages"].items() if k.startswith(("hold.", "toast.", "move.", "reorder.", "chip.", "box."))]
bad = [v for v in new if re.search(r"Pronto para|Revisão da spec|Codificação|Entrada\b", v)]
sys.exit(1 if bad else 0)' "$(nat "$CAT")"; then pass "AC-8 the new entries keep the column names in English"; else fail "AC-8 a new entry translates a column name"; fi
finish
