#!/usr/bin/env bash
# The dashboard's quick approve (#50). A decision in its 5 s wait is sent when the page goes away, and the list asks
# whether the review has been seen. The browser parts (Undo, the drawer's confirmation, the failed-send message) are
# checked by hand; here: the server side with a fake gh, and dashboard.html read as text.
#   AC-1  an approve whose client hangs up right after sending still moves the card, with no error logged
#   AC-3  a second approve for the same card with the old column is a 409 and moves nothing
#   AC-5  the overview says whether a awaiting card has a review page
#   AC-7  a request-changes with a note from a client that hangs up posts the note and moves the card
#   page  a pagehide listener sends what is waiting, with keepalive
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
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"; port="${base##*:}"
H_TOK="X-Shipfloor-Token: $tok"
post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_TOK" "$@"; }

# hangup <api/... path, no leading slash (Git Bash would rewrite it)> <json body>: sends the request, then closes the socket (a reset) without reading the answer,
# as a tab does that is closed right after its fetch left
hangup() {
  $PY -I -c '
import socket, struct, sys, time
port, path, tok, body = sys.argv[1:5]
s = socket.create_connection(("127.0.0.1", int(port)))
head = "POST /%s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nX-Shipfloor-Token: %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (path, port, tok, len(body))
s.sendall(head.encode() + body.encode())
time.sleep(0.3)
s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
s.close()' "$port" "$1" "$tok" "$2"
}
# wait_for <file> <text>: up to 20 s for the file to hold the text
wait_for() { local i; for i in $(seq 1 100); do grep -qs "$2" "$1" && return 0; sleep 0.2; done; return 1; }
edits() { if [ -f "$FAKE_GH_DIR/edits" ]; then grep -c 'item-edit' "$FAKE_GH_DIR/edits" | tr -d '\r'; else echo 0; fi; }

# the board: 9 and 10 in Staged, 11 in Coding
printf 'PVTI_9\t9\t👤 Staged\nPVTI_10\t10\t👤 Staged\nPVTI_11\t11\t🤖 Coding\n' > "$FAKE_GH_DIR/items.tsv"

# AC-1: Approve on a Staged card (no note), the client gone before the answer: the card still moves to Ready for Prod
hangup api/card/shop/9/approve '{"column":"Staged"}'
wait_for "$FAKE_GH_DIR/edits" 'PVTI_9.*opt9' && pass "AC-1 the card moved to Ready for Prod after the client hung up" || fail "AC-1 the card did not move after the client hung up (edits: $(edits))"
sleep 1.5
[ "$(edits)" = 1 ] && pass "AC-1 the card moved once" || fail "AC-1 the card moved $(edits) times, want 1"
if grep -qiE 'traceback|exception|error' "$FAKE_GH_DIR/out"; then
  fail "AC-1 the server logged an error for the client that hung up: $(grep -iE 'traceback|exception|error' "$FAKE_GH_DIR/out" | head -n 1)"
else pass "AC-1 the hung-up client leaves no error in the server log"; fi

# AC-3: the board now has 9 in Ready for Prod; a second approve still carrying Staged is refused and moves nothing
printf 'PVTI_9\t9\t👤 Ready for Prod\nPVTI_10\t10\t👤 Staged\nPVTI_11\t11\t🤖 Coding\n' > "$FAKE_GH_DIR/items.tsv"
got="$(post -d '{"column":"Staged"}' "$base/api/card/shop/9/approve")"
[ "$got" = 409 ] && pass "AC-3 a second approve with the old column answers 409" || fail "AC-3 a second approve answered $got, want 409"
[ "$(edits)" = 1 ] && pass "AC-3 the second approve moved nothing" || fail "AC-3 the card was moved again ($(edits) moves, want 1)"

# AC-5: the overview says whether a card has a review page; only a card that waits for the owner reads it
: > "$FAKE_GH_DIR/calls"
printf '9\tStaged\n10\tStaged\n11\tCoding\n' > "$P/board.tsv"
echo '<p>review</p>' > "$P/reviews/9.html"; echo '<p>review</p>' > "$P/reviews/11.html"
review_of() {
  curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; n=int(sys.argv[1]); print(next((json.dumps(c.get("review", "<missing>")) for c in json.load(sys.stdin)["projects"][0]["cards"] if c["issue"] == n), "<no card>"))' "$1" | tr -d '\r'
}
want_review() {  # want_review <what> <card> <want>
  local got; got="$(review_of "$2")"
  [ "$got" = "$3" ] && pass "$1" || fail "$1: review is $got, want $3"
}
want_review "AC-5 a Staged card with a review page says review: true" 9 true
want_review "AC-5 a Staged card without a review page says review: false" 10 false
want_review "AC-5 a card in Coding says review: false even with a page" 11 false

# AC-7: request-changes with a note, the client gone: the note is posted and the card goes back to Coding
rm -f "$FAKE_GH_DIR/edits" "$FAKE_GH_DIR/comments"
printf 'PVTI_9\t9\t👤 Ready for Prod\nPVTI_10\t10\t👤 Staged\nPVTI_11\t11\t🤖 Coding\n' > "$FAKE_GH_DIR/items.tsv"
hangup api/card/shop/10/request-changes '{"column":"Staged","text":"fix the header"}'
wait_for "$FAKE_GH_DIR/edits" 'PVTI_10.*opt6' && pass "AC-7 the card went back to Coding after the client hung up" || fail "AC-7 the card did not move after the client hung up"
sleep 1.5
assert_contains "$(cat "$FAKE_GH_DIR/comments" 2>/dev/null)" "fix the header"
if [ "$(grep -ciE 'traceback|exception' "$FAKE_GH_DIR/out" | tr -d '\r')" = 0 ]; then pass "AC-7 the hung-up client leaves no traceback in the server log"
else fail "AC-7 the server logged a traceback for the client that hung up"; fi

# page, read as text: a pagehide listener sends what waits (the list's pending and the Inbox's held decision) with keepalive
pagehide="$($PY -I -c '
import sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.find("pagehide")
print(t[i:i + 1500] if i >= 0 else "<no pagehide>")' "$(nat "$FACTORY_DIR/dashboard.html")" | tr -d '\r')"
case "$pagehide" in "<no pagehide>"*) fail "page: dashboard.html has no pagehide listener" ;; *) pass "page: dashboard.html has a pagehide listener" ;; esac
case "$pagehide" in *keepalive*) pass "page: the pagehide send uses keepalive" ;; *) fail "page: the pagehide listener does not send with keepalive" ;; esac
case "$pagehide" in *S.pending*) pass "page: pagehide sends the list's pending decisions" ;; *) fail "page: pagehide does not read S.pending" ;; esac
case "$pagehide" in *INB.hold*) pass "page: pagehide sends the Inbox's held decision" ;; *) fail "page: pagehide does not read INB.hold" ;; esac
finish
