#!/usr/bin/env bash
# The dashboard's card titles: a failed read is not remembered as "no titles", a read that worked is not
# repeated inside the cache window, and a card is asked for by number (no 300-issue reach).
# Each scenario starts its own dashboard on its own fake gh folder. gh is turned off with $FAKE_GH_DIR/fail;
# a title read is a line of $FAKE_GH_DIR/calls with issueOrPullRequest (a failing call is never logged).
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
srv=""; trap 'kill $srv 2>/dev/null' EXIT

# start_dash "<number>\t<title>" ...: a fresh fake gh folder with those titles, and a dashboard on it
start_dash() {
  [ -n "$srv" ] && kill $srv 2>/dev/null
  export FAKE_GH_DIR="$(mktemp -d)"
  : > "$FAKE_GH_DIR/titles.tsv"
  local t; for t in "$@"; do printf '%b\n' "$t" >> "$FAKE_GH_DIR/titles.tsv"; done
  $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
  srv=$!
  for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
  local url; url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
  H_TOK="X-Shipfloor-Token: $tok"
}
# board <n>...: the board snapshot, all in Staged, fresh (so the dashboard does not read the board itself)
board() { local n; : > "$P/board.tsv"; for n in "$@"; do printf '%s\tStaged\n' "$n" >> "$P/board.tsv"; done; }
overview() { curl -s -w '\n%{http_code}' -H "$H_TOK" "$base/api/overview" | tr -d '\r'; }
# title_of <n>: the overview's title for card n ("<no card>" when the board has none), after a fresh board
title_of() {
  curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; n=int(sys.argv[1]); print(next((c["title"] for c in json.load(sys.stdin)["projects"][0]["cards"] if c["issue"] == n), "<no card>"))' "$1" | tr -d '\r'
}
card_title() { curl -s -H "$H_TOK" "$base/api/card/shop/$1" | $PY -c 'import json,sys; print(json.load(sys.stdin)["title"])' | tr -d '\r'; }
reads() { if [ -f "$FAKE_GH_DIR/calls" ]; then grep -c issueOrPullRequest "$FAKE_GH_DIR/calls" | tr -d '\r'; else echo 0; fi; }
want_title() {  # want_title <what> <got> <want>
  [ "$2" = "$3" ] && pass "$1" || fail "$1: title '$2', want '$3'"
}

# AC-1: the first read fails; gh works again; one poll later every card has its title
start_dash '41\tForty-one' '42\tForty-two'
touch "$FAKE_GH_DIR/fail"; board 41 42; title_of 41 > /dev/null
rm "$FAKE_GH_DIR/fail"; board 41 42
want_title "AC-1 after a failed first read, one poll gives card 41 its title" "$(title_of 41)" "Forty-one"
want_title "AC-1 after a failed first read, one poll gives card 42 its title" "$(title_of 42)" "Forty-two"

# AC-2: titles were read; a later read (for a card that appeared) fails; the known titles stay, none empty
start_dash '41\tForty-one' '42\tForty-two' '43\tForty-three'
board 41 42
want_title "AC-2 titles were read before the failure (card 41)" "$(title_of 41)" "Forty-one"
touch "$FAKE_GH_DIR/fail"; board 41 42 43
want_title "AC-2 a failed read keeps card 41's title" "$(title_of 41)" "Forty-one"
want_title "AC-2 a failed read keeps card 42's title" "$(title_of 42)" "Forty-two"

# AC-3: a failed read is asked again on the next poll, not after the cache window
start_dash '41\tForty-one'
touch "$FAKE_GH_DIR/fail"; board 41; title_of 41 > /dev/null
rm "$FAKE_GH_DIR/fail"; : > "$FAKE_GH_DIR/calls"; board 41; title_of 41 > /dev/null
[ "$(reads)" -ge 1 ] && pass "AC-3 gh is asked for titles again on the poll after a failed read" || fail "AC-3 no title read on the poll after a failed read (reads: $(reads))"

# AC-4: a read that worked is not repeated inside the window
start_dash '41\tForty-one' '42\tForty-two'
board 41 42; title_of 41 > /dev/null
first="$(reads)"
[ "$first" = 1 ] && pass "AC-4 the first poll reads the titles of both cards in one call" || fail "AC-4 the first poll made $first title reads, want 1"
board 41 42; title_of 41 > /dev/null; board 41 42; title_of 42 > /dev/null
[ "$(reads)" = "$first" ] && [ "$first" -ge 1 ] && pass "AC-4 polls inside the window do not ask gh for titles again" || fail "AC-4 title reads went from $first to $(reads) inside the window"

# AC-5: a card far beyond the 300 newest issues (its title is only in titles.tsv) has its title
start_dash '41\tForty-one' '4321\tFar away'
board 41 4321
want_title "AC-5 a card numbered above 300 carries its title" "$(title_of 4321)" "Far away"

# AC-6: the first read failed, gh works again: the card endpoint has the title
start_dash '41\tForty-one' '42\tForty-two'
touch "$FAKE_GH_DIR/fail"; board 41 42; title_of 41 > /dev/null
rm "$FAKE_GH_DIR/fail"; board 41 42
want_title "AC-6 /api/card has the title after a failed first read" "$(card_title 41)" "Forty-one"

# AC-7: gh fails on every read: still 200, the board's cards, empty titles (holds today too: a guard)
start_dash '41\tForty-one' '42\tForty-two'
touch "$FAKE_GH_DIR/fail"; board 41 42
got="$(overview)"
[ "$(printf '%s\n' "$got" | tail -n 1)" = 200 ] && pass "AC-7 the overview answers 200 while gh fails" || fail "AC-7 the overview did not answer 200"
want_title "AC-7 card 41 is on the board with an empty title" "$(title_of 41)" ""
want_title "AC-7 card 42 is on the board with an empty title" "$(title_of 42)" ""
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "$H_TOK" "$base/api/card/shop/41")" = 200 ] && pass "AC-7 the card answers 200 while gh fails" || fail "AC-7 the card did not answer 200"
want_title "AC-7 the card's title is empty" "$(card_title 41)" ""
finish
