#!/usr/bin/env bash
# The dashboard as a process (its API is tested in process by dashboard-{cards,settings,views}.test.sh): it starts on a
# free port and prints its URL, a second one moves to another port, the link survives a restart and a lost secret is
# replaced, --token picks the token, and started directly with no SHIPFLOOR_BASH it finds its own bash or refuses.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
PYABS="$(command -v $PY)"
W="$(mktemp -d)"; H="$SHIPFLOOR_HOME"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews" "$W/empty"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
export FAKE_GH_DIR="$W/gh"; mkdir -p "$FAKE_GH_DIR"
export FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 CLAUDE_CONFIG_DIR="$(nat "$W/claude")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")"
DASH="$(nat "$FACTORY_DIR/dashboard.py")"
PIDS=""; MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; kill $PIDS 2>/dev/null' EXIT
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

start() {  # start <tag> <dashboard args...>: a server on the temp home; sets srv, url, base, tok, port
  local tag="$1"; shift
  $PY -I "$DASH" --home "$(nat "$H")" --no-open "$@" > "$W/out-$tag" 2>&1 &
  srv=$!; PIDS="$PIDS $srv"
  for _ in $(seq 1 100); do grep -qs 'http://' "$W/out-$tag" && break; sleep 0.05; done
  url="$(grep -o 'http://[^ ]*' "$W/out-$tag" | tr -d '\r')"; base="${url%%/?t=*}"; tok="${url##*t=}"; port="${base##*:}"
}
stop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
is_token() { [[ "$1" =~ ^[A-Za-z0-9_-]{22}$ ]]; }

# a fresh home: a random 22-character token (an empty --token keeps it), saved, and it opens the API
start a --port 0 --token ""; A=$srv; url1="$url"; tok1="$tok"; port1="$port"
is_token "$tok1" && pass "the first start prints a URL with a random 22-character token" || fail "no URL with a token was printed: '$url1' ($(head -c 300 "$W/out-a"))"
[ "$(tr -d '\r\n' < "$H/dashboard.token" 2>/dev/null)" = "$tok1" ] && pass "the token is saved in dashboard.token" || fail "dashboard.token does not hold the printed token"
[ "$(code -H "X-Shipfloor-Token: $tok1" "$base/api/overview")" = 200 ] && pass "the printed token opens the API" || fail "the printed token was refused"
# a second dashboard never shares the first one's port (Windows lets two sockets bind it with SO_REUSEADDR)
start b --port "$port1"
[ -n "$url" ] && [ "$port" != "$port1" ] && pass "a second dashboard moves to another port" || fail "the second dashboard: '$url' (the first is on $port1)"
stop $srv

# AC-1/AC-2 (#52): stopped and started again on the same home and port, the URL is the same and the old token still works
stop $A
start c --port "$port1"
[ -n "$url1" ] && [ "$url" = "$url1" ] && pass "the URL after a restart is the one printed before" || fail "the URL changed across a restart: '$url1' then '$url'"
[ "$(code -H "X-Shipfloor-Token: $tok1" "$base/api/overview")" = 200 ] && pass "the first run's token opens the restarted server" || fail "the first run's token was refused after a restart"
stop $srv

# AC-5: the saved secret lost: a new token, the old link refused (the damaged-file cases are in dashboard_views.LinkToken)
rm -f "$H/dashboard.token"
start d --port 0
is_token "$tok" && [ "$tok" != "$tok1" ] && pass "a lost secret is replaced by a new token" || fail "the token after losing dashboard.token: '$tok'"
[ "$(code -H "X-Shipfloor-Token: $tok1" "$base/api/overview")" = 403 ] && pass "the old token gets 403" || fail "the old token is still accepted"
stop $srv

# --token x (the demo stack's fixed token) is the link's token
start e --port 0 --token x
[ "${url##*\?t=}" = x ] && [ "$(code -H "X-Shipfloor-Token: x" "$base/api/overview")" = 200 ] && pass "with --token x the URL carries ?t=x and x opens the API" || fail "--token x printed '$url'"
stop $srv

unset SHIPFLOOR_BASH
# AC-4/AC-5 (no SHIPFLOOR_BASH, no bash on PATH, Python by its absolute path): it refuses at start, one line, no URL
env PATH="$W/empty" "$PYABS" -I "$DASH" --home "$(nat "$H")" --port 0 --no-open > "$W/ref.out" 2> "$W/ref.err" &
srv=$!; PIDS="$PIDS $srv"
for _ in $(seq 1 100); do kill -0 $srv 2>/dev/null || break; sleep 0.05; done
if kill -0 $srv 2>/dev/null; then
  fail "the server started with no bash on PATH and SHIPFLOOR_BASH unset (out: $(head -c 200 "$W/ref.out"))"
else
  wait $srv; rc=$?
  [ "$rc" -ne 0 ] && pass "no bash found: it exits non-zero ($rc)" || fail "no bash found: it exited 0"
  ! grep -qs 'http://' "$W/ref.out" "$W/ref.err" && pass "no bash found: no URL printed, nothing served" || fail "a URL was printed although no bash was found"
  [ "$(wc -l < "$W/ref.err" | tr -d ' ')" = 1 ] && pass "no bash found: stderr is one line" || fail "stderr is not one line: $(cat "$W/ref.err")"
  assert_contains "$(cat "$W/ref.err")" "SHIPFLOOR_BASH"
  assert_contains "$(cat "$W/ref.err")" "shipfloor dashboard"
fi

# AC-1/AC-2/AC-7: the test's own PATH and SHIPFLOOR_BASH unset: it finds a bash, reads titles through gh and moves a card
start f --port 0
if [ -z "$url" ]; then fail "the server did not start with a bash on PATH and SHIPFLOOR_BASH unset: $(head -c 300 "$W/out-f")"
else
  pass "it starts with a bash on PATH and SHIPFLOOR_BASH unset"
  H_TOK="X-Shipfloor-Token: $tok"
  got="$(curl -s -H "$H_TOK" "$base/api/card/shop/7" | $PY -c 'import json,sys; print(json.load(sys.stdin)["title"])' | tr -d '\r')"
  [ "$got" = Seven ] && pass "the card shows its issue title" || fail "title is '$got', want 'Seven'"
  printf 'PVTI_7\t7\t👤 Spec Review\n' > "$FAKE_GH_DIR/items.tsv"
  [ "$(code -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d '{"column":"Spec Review"}' "$base/api/card/shop/7/approve")" = 200 ] && pass "approve answers 200" || fail "approve did not answer 200"
  assert_contains "$(cat "$FAKE_GH_DIR/edits" 2>/dev/null)" "--id PVTI_7 --field-id FLD_x --single-select-option-id opt5"
fi
stop $srv
finish
