#!/usr/bin/env bash
# The local dashboard: what a card cost (from Claude Code transcripts) and the owner's two actions.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$AGHANIM_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"

# card 7: a develop session (two log lines per API message, one subagent), a legacy refine session,
# a manual session in control (ignored) and a half-written last line
T="$C/projects/C--x--aghanim-projects-shop-control"; mkdir -p "$T/s1/subagents"
cmd() { printf '{"type":"user","timestamp":"2026-10-09T10:00:00Z","message":{"role":"user","content":%s}}\n' "$1"; }
ast() { printf '{"type":"assistant","timestamp":"2026-10-09T10:05:00Z","message":{"id":"%s","model":"%s","usage":%s}}\n' "$1" "$2" "$3"; }
U='{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}'
{ cmd '"<command-message>aghanim:develop</command-message>\n<command-name>/aghanim:develop</command-name>\n<command-args>7</command-args>"'
  ast m1 claude-opus-5-5 "$U"; ast m1 claude-opus-5-5 "$U"; printf '{"type":"assistant","mess'; } > "$T/s1.jsonl"
ast a1 claude-sonnet-5-5 '{"input_tokens":0,"output_tokens":1000000}' > "$T/s1/subagents/agent-a.jsonl"
{ cmd '[{"type":"text","text":"<command-name>/mylos:refinar</command-name>\n<command-args>7</command-args>"}]'
  ast m2 claude-haiku-5-5 '{"input_tokens":1000000,"output_tokens":0}'; } > "$T/s2.jsonl"
{ cmd '"hello"'; ast m3 claude-opus-5-5 '{"input_tokens":1000000,"output_tokens":0}'; } > "$T/s3.jsonl"

export CLAUDE_CONFIG_DIR="$(nat "$C")" AGHANIM_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# a second dashboard never shares the first one's port (Windows lets two sockets bind it with SO_REUSEADDR)
port="${base##*:}"
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port "$port" --no-open > "$FAKE_GH_DIR/out2" 2>&1 &
srv2=$!; trap 'kill $srv $srv2 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out2" && break; sleep 0.1; done
case "$(cat "$FAKE_GH_DIR/out2")" in *"127.0.0.1:$port/"*) fail "second dashboard took port $port too" ;; *) pass "second dashboard moved to another port" ;; esac
kill $srv2 2>/dev/null

# opus 1M input $4 + 0.1M output $2 + 1M cache read $0.20 + 1M 1h cache write $8 = 14.20, once;
# subagent sonnet 1M output $10; legacy refine haiku 1M input $0.10; the manual session is not the card's
H_TOK="X-Aghanim-Token: $tok"
got="$(curl -s -H "$H_TOK" "$base/api/card/shop/7" | $PY -c 'import json,sys; c=json.load(sys.stdin); print(c["total"], len(c["sessions"]), ",".join(sorted(s["stage"] for s in c["sessions"])))')"
assert_contains "$got" "24.3 2 develop,refine"
# titles and block labels come from JSON (no --jq): #7 is "Seven" and blocked
got="$(curl -s -H "$H_TOK" "$base/api/card/shop/7" | $PY -c 'import json,sys; c=json.load(sys.stdin); print(c["title"], c["blocked"], c["block_reason"])')"
assert_contains "$got" "Seven owner **Validate blocked (infrastructure)**: stack down"
[ "$(code "$base/api/card/shop/7")" = 403 ] && pass "no token, no data" || fail "served without the token"
[ "$(code -H "$H_TOK" "$base/api/log/shop/..%2F..%2Fregistry.tsv")" = 404 ] && pass "no path outside logs" || fail "served a file outside logs"

# the feed is one timeline: dispatcher lines and one line per run by time, an untimed line after the timed one above it
D="$(date +%F)"; mkdir -p "$H/logs"
printf '%sT10:00:00-03:00 aghanim: shop: first\nmv: stderr\n%sT10:10:00-03:00 aghanim: shop: last\n' "$D" "$D" > "$H/logs/dispatcher.log"
printf '== start /aghanim:develop 7 %sT10:05:00-03:00 pid=1\n== end /aghanim:develop 7 exit=4 %sT10:06:00-03:00\n' "$D" "$D" > "$P/logs/$D-7-develop.log"
got="$(curl -s -H "$H_TOK" "$base/api/feed" | $PY -c 'import json,sys; print(" | ".join(e["text"] + (" exit=%s" % e["exit"] if e.get("issue") else "") for e in json.load(sys.stdin)["events"]))')"
assert_contains "$got" "aghanim: shop: first | mv: stderr | develop #7 exit=4 | aghanim: shop: last"
[ "$(code "$base/api/feed")" = 403 ] && pass "no token, no feed" || fail "served the feed without the token"
rm "$P/logs/$D-7-develop.log"
# the overview says how long a stage usually takes (clean runs only) and when a card's last run ended
printf '== start /aghanim:develop 7 2026-10-09T10:00:00-03:00 pid=1\n== end /aghanim:develop 7 exit=0 2026-10-09T10:01:00-03:00\n== start /aghanim:develop 7 2026-10-09T11:00:00-03:00 pid=2\n== end /aghanim:develop 7 exit=4 2026-10-09T11:30:00-03:00\n' > "$P/logs/2026-10-09-7-develop.log"
printf '7	Staged
' > "$P/board.tsv"
got="$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; p=json.load(sys.stdin)["projects"][0]; print(p["typical_s"], [c["since"] for c in p["cards"] if c["issue"] == 7])')"
assert_contains "$got" "{'develop': 60} ['2026-10-09T11:30:00-03:00']"
rm "$P/logs/2026-10-09-7-develop.log" "$P/board.tsv"

# a live run tells its step (as its place among the stage's steps) and the last things its session did
mkdir -p "$P/locks/validate-9.lock"; printf '1 1791600000 9\n' > "$P/locks/validate-9.lock/info"; printf '3\t1791600300\n' > "$P/locks/validate-9.lock/step"
{ cmd '"<command-name>/aghanim:validate</command-name>\n<command-args>9</command-args>"'
  printf '{"type":"assistant","timestamp":"2026-10-09T10:06:00Z","message":{"id":"m9","content":[{"type":"text","text":"The e2e gate failed; reading its log."},{"type":"tool_use","name":"Bash","input":{"description":"Rerun the e2e gate","command":"x"}}]}}\n'; } > "$T/s4.jsonl"
got="$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runs"] if x["issue"] == 9][0]; print(r["step"]["i"], r["steps"], r["step"]["label"], "|".join(a["kind"] + ":" + a["text"] for a in r["activity"]))')"
assert_contains "$got" "3 5 Review says:The e2e gate failed; reading its log.|Bash:Rerun the e2e gate"
rm -r "$P/locks/validate-9.lock" "$T/s4.jsonl"

# a project the dispatcher skips says so in the overview
printf '2026-10-09T20:06:50-03:00	cannot bring the control checkout to origin/main: index.lock exists
' > "$P/SKIPPED"
got="$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; s=json.load(sys.stdin)["projects"][0]["skipped"]; print(s["since"], s["reason"])')"
assert_contains "$got" "2026-10-09T20:06:50-03:00 cannot bring the control checkout"
rm "$P/SKIPPED"

# owner actions: the board says 7 is in Spec Review, 8 in Coding, 9 in Staged
printf 'PVTI_7\t7\t👤 Spec Review\nPVTI_8\t8\t🤖 Coding\nPVTI_9\t9\t👤 Staged\n' > "$FAKE_GH_DIR/items.tsv"
post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$@"; }
# the token only counts in the header: a page can put it in a URL, not in a header without a preflight
[ "$(post -d '{"column":"Spec Review"}' "$base/api/card/shop/7/approve?t=$tok")" = 403 ] && pass "token in the URL does not act" || fail "acted with the token in the URL"
# agent-written review pages run sandboxed, away from the dashboard's origin and token
echo '<p>spec</p>' > "$P/reviews/7.html"
assert_contains "$(curl -s -D - -o /dev/null "$base/review/shop/7?t=$tok" | tr -d '
')" "Content-Security-Policy: sandbox allow-scripts"
# one unreadable transcript does not take the board down
printf '%s
' '{"type":"user","timestamp":"not a time","message":{"content":"<command-name>/aghanim:develop</command-name><command-args>8</command-args>"}}' > "$T/bad.jsonl"
[ "$(code -H "$H_TOK" "$base/api/card/shop/8")" = 200 ] && pass "a bad transcript is skipped" || fail "a bad transcript broke the overview"
[ "$(post -d '{"column":"Spec Review"}' "$base/api/card/shop/7/approve")" = 403 ] && pass "no token, no action" || fail "acted without the token"
[ "$(post -d '{"column":"Coding"}' "$base/api/card/shop/8/approve" -H "$H_TOK")" = 409 ] && pass "Coding is not the owner's" || fail "approved a card in Coding"
[ ! -e "$FAKE_GH_DIR/edits" ] && pass "nothing moved" || fail "moved a card it should not"
[ "$(post -d '{"column":"Spec Review"}' "$base/api/card/shop/7/approve" -H "$H_TOK")" = 200 ] && pass "approved" || fail "approve failed"
assert_contains "$(cat "$FAKE_GH_DIR/edits")" "--id PVTI_7 --field-id FLD_x --single-select-option-id opt5"
[ "$(post -d '{"column":"Staged","text":"fix the header"}' "$base/api/card/shop/9/request-changes" -H "$H_TOK")" = 200 ] && pass "changes requested" || fail "request-changes failed"
assert_contains "$(cat "$FAKE_GH_DIR/comments")" "fix the header"
c="$(grep -n '^issue comment 9' "$FAKE_GH_DIR/calls" | cut -d: -f1)"; m="$(grep -n 'item-edit.*PVTI_9.*opt6' "$FAKE_GH_DIR/calls" | cut -d: -f1)"
[ -n "$c" ] && [ -n "$m" ] && [ "$c" -lt "$m" ] && pass "comment first, then back to Coding" || fail "comment $c, move $m"
# unblock: owner action, header token only, removes both block labels
[ "$(post -d '{}' "$base/api/card/shop/7/unblock")" = 403 ] && pass "no token, no unblock" || fail "unblocked without the token"
[ "$(post -d '{}' "$base/api/card/shop/7/unblock" -H "$H_TOK")" = 200 ] && pass "unblocked" || fail "unblock failed"
assert_contains "$(cat "$FAKE_GH_DIR/calls")" "api -X DELETE repos/acme/shop/issues/7/labels/blocked:infra"
# Live: card 11 has a run working (its lock). Its session's steps and the messages it was handed come from
# the transcript; a new message waits in the run's inbox until the run's hook hands it over, once per agent.
L="$P/locks/develop-11.lock"; mkdir -p "$L"; echo "1 $(date +%s) 11" > "$L/info"
intro="$($PY -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import inbox_hook; print(inbox_hook.INTRO)' "$(nat "$FACTORY_DIR")" | tr -d '\r')"
{ cmd '"<command-name>/aghanim:develop</command-name>\n<command-args>11</command-args>"'
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-09T10:01:00Z","message":{"content":[{"type":"text","text":"Planning the work."},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
  printf '{"type":"attachment","timestamp":"2026-10-09T10:02:00Z","attachment":{"type":"hook_additional_context","content":["%s\\n\\nuse the old header"]}}\n' "$intro"; } > "$T/s4.jsonl"
live() { curl -s -H "$H_TOK" "$base/api/live/shop/11" | $PY -c 'import json,sys; s=json.load(sys.stdin); print(s["running"], [(e["kind"], e["text"]) for e in s["events"]], "pending", [m["text"] for m in s["pending"]])'; }
assert_contains "$(live)" "True [('says', 'Planning the work.'), ('Bash', 'ls'), ('owner', 'use the old header')] pending []"
[ "$(post -d '{"text":"keep the footer"}' "$base/api/card/shop/11/message")" = 403 ] && pass "no token, no message" || fail "took a message without the token"
[ "$(post -d '{"text":"keep the footer"}' "$base/api/card/shop/7/message" -H "$H_TOK")" = 409 ] && pass "no run, no message" || fail "took a message for a card nobody works on"
[ "$(post -d '{"text":" "}' "$base/api/card/shop/11/message" -H "$H_TOK")" = 400 ] && pass "an empty message is refused" || fail "took an empty message"
[ "$(post -d '{"text":"keep the \"footer\""}' "$base/api/card/shop/11/message" -H "$H_TOK")" = 200 ] && pass "message queued" || fail "message failed"
assert_contains "$(live)" "pending ['keep the \"footer\"']"
hook() { echo "$1" | AGHANIM_RUN_LOCK="$(nat "$L")" bash "$FACTORY_DIR/inbox-hook.sh" | $PY -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "nothing")'; }
assert_contains "$(hook '{}')" 'keep the "footer"'
assert_contains "$(hook '{}')" "nothing"
assert_contains "$(hook '{"agent_id":"a1"}')" 'keep the "footer"'
assert_contains "$(live)" "pending []"
assert_contains "$(echo '{}' | AGHANIM_RUN_LOCK="$(nat "$P/locks/none.lock")" bash "$FACTORY_DIR/inbox-hook.sh"; echo "rc=$?")" "rc=0"
# the overview lists the runs that ended today, newest first (the Today panel), and the deploy script's own
# lock inside a deploy run is not a second run
printf '== start /aghanim:refine 12 %sT08:00:00-03:00 pid=1
== end /aghanim:refine 12 exit=0 %sT08:09:00-03:00
== start /aghanim:refine 12 %sT09:00:00-03:00 pid=2
== end /aghanim:refine 12 exit=3 %sT09:01:00-03:00
' "$D" "$D" "$D" "$D" > "$P/logs/$D-12-refine.log"
mkdir -p "$P/locks/deploysh-11.lock"; echo "1 $(date +%s) 11" > "$P/locks/deploysh-11.lock/info"
got="$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; o=json.load(sys.stdin); print([(r["issue"], r["stage"], r["exit"], r["cost"]) for r in o["projects"][0]["ended"]], sorted({r["stage"] for r in o["runs"]}))')"
assert_contains "$got" "[(12, 'refine', 3, None), (12, 'refine', 0, None)] ['develop']"
finish
