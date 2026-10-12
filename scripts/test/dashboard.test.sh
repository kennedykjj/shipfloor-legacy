#!/usr/bin/env bash
# The local dashboard: what a card cost (from Claude Code transcripts) and the owner's two actions.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"

# card 7: a develop session (two log lines per API message, one subagent), a legacy refine session,
# a manual session in control (ignored) and a half-written last line
T="$C/projects/C--x--shipfloor-projects-shop-control"; mkdir -p "$T/s1/subagents"
cmd() { printf '{"type":"user","timestamp":"2026-10-09T10:00:00Z","message":{"role":"user","content":%s}}\n' "$1"; }
ast() { printf '{"type":"assistant","timestamp":"2026-10-09T10:05:00Z","message":{"id":"%s","model":"%s","usage":%s}}\n' "$1" "$2" "$3"; }
U='{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}'
{ cmd '"<command-message>sf:develop</command-message>\n<command-name>/sf:develop</command-name>\n<command-args>7</command-args>"'
  ast m1 claude-opus-5-5 "$U"; ast m1 claude-opus-5-5 "$U"; printf '{"type":"assistant","mess'; } > "$T/s1.jsonl"
ast a1 claude-sonnet-5-5 '{"input_tokens":0,"output_tokens":1000000}' > "$T/s1/subagents/agent-a.jsonl"
{ cmd '[{"type":"text","text":"<command-name>/mylos:refinar</command-name>\n<command-args>7</command-args>"}]'
  ast m2 claude-haiku-5-5 '{"input_tokens":1000000,"output_tokens":0}'; } > "$T/s2.jsonl"
{ cmd '"hello"'; ast m3 claude-opus-5-5 '{"input_tokens":1000000,"output_tokens":0}'; } > "$T/s3.jsonl"

export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
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
H_TOK="X-Shipfloor-Token: $tok"
got="$(curl -s -H "$H_TOK" "$base/api/card/shop/7" | $PY -c 'import json,sys; c=json.load(sys.stdin); print(c["total"], len(c["sessions"]), ",".join(sorted(s["stage"] for s in c["sessions"])))')"
assert_contains "$got" "24.3 2 develop,refine"
# titles and block labels come from JSON (no --jq): #7 is "Seven" and blocked
got="$(curl -s -H "$H_TOK" "$base/api/card/shop/7" | $PY -c 'import json,sys; c=json.load(sys.stdin); print(c["title"], c["blocked"], c["block_reason"])')"
assert_contains "$got" "Seven owner **Validate blocked (infrastructure)**: stack down"
[ "$(code "$base/api/card/shop/7")" = 403 ] && pass "no token, no data" || fail "served without the token"
[ "$(code -H "$H_TOK" "$base/api/log/shop/..%2F..%2Fregistry.tsv")" = 404 ] && pass "no path outside logs" || fail "served a file outside logs"

# the feed is one timeline: dispatcher lines and one line per run by time, an untimed line after the timed one above it
D="$(date +%F)"; mkdir -p "$H/logs"
printf '%sT10:00:00-03:00 shipfloor: shop: first\nmv: stderr\n%sT10:10:00-03:00 shipfloor: shop: last\n%sT10:20:00-03:00 shipfloor: shop: again\n%sT10:23:00-03:00 shipfloor: shop: again\n' "$D" "$D" "$D" "$D" > "$H/logs/dispatcher.log"
printf '== start /sf:develop 7 %sT10:05:00-03:00 pid=1\ngate build: 2 tests failed\n\n== end /sf:develop 7 exit=4 %sT10:06:00-03:00\n' "$D" "$D" > "$P/logs/$D-7-develop.log"
got="$(curl -s -H "$H_TOK" "$base/api/feed" | $PY -c 'import json,sys; print(" | ".join(e["text"] + (" exit=%s" % e["exit"] if e.get("issue") else "") for e in json.load(sys.stdin)["events"]))')"
assert_contains "$got" "shipfloor: shop: first | mv: stderr | develop #7 exit=4 | shipfloor: shop: last | shipfloor: shop: again"
# a line repeated in a row is one event, and a run says what it left behind: the card's title, and its last words when it failed
got="$(curl -s -H "$H_TOK" "$base/api/feed" | $PY -c 'import json,sys; ev=json.load(sys.stdin)["events"]; a=ev[-1]; r=[e for e in ev if e.get("issue")][0]; print(a["n"], a["since"][11:16], a["ts"][11:16], "|", r["stage"], r["title"], "|", r["last"])')"
assert_contains "$got" "2 10:20 10:23 | develop Seven | gate build: 2 tests failed"
# a run with no end and no lock is not running: its end was lost
printf '== start /sf:refine 7 %sT09:00:00-03:00 pid=1\n' "$D" > "$P/logs/$D-7-refine.log"
got="$(curl -s -H "$H_TOK" "$base/api/feed" | $PY -c 'import json,sys; print([e.get("lost") for e in json.load(sys.stdin)["events"] if e.get("stage") == "refine"])')"
assert_contains "$got" "[True]"; rm -f "$P/logs/$D-7-refine.log"
[ "$(code "$base/api/feed")" = 403 ] && pass "no token, no feed" || fail "served the feed without the token"
# the page's language is the machine's: English sends no catalog, pt-BR sends its own
lang() { curl -s -H "$H_TOK" "$base/api/lang" | $PY -c 'import json,sys; d=json.load(sys.stdin); print(d["language"], len(d["exact"]) > 50, len(d["rx"]) > 20, d["exact"].get("Close", ""))'; }
assert_contains "$(lang)" "en False False"
[ -f "$H/config.yml" ] && cp "$H/config.yml" "$H/config.yml.bak"; echo "language: pt-BR" >> "$H/config.yml"
assert_contains "$(lang)" "pt-BR True True Fechar"
if [ -f "$H/config.yml.bak" ]; then mv "$H/config.yml.bak" "$H/config.yml"; else rm "$H/config.yml"; fi
rm "$P/logs/$D-7-develop.log"
# the overview says how long a stage usually takes (clean runs only) and when a card's last run ended
printf '== start /sf:develop 7 2026-10-09T10:00:00-03:00 pid=1\n== end /sf:develop 7 exit=0 2026-10-09T10:01:00-03:00\n== start /sf:develop 7 2026-10-09T11:00:00-03:00 pid=2\n== end /sf:develop 7 exit=4 2026-10-09T11:30:00-03:00\n' > "$P/logs/2026-10-09-7-develop.log"
printf '7	Staged
' > "$P/board.tsv"
got="$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; p=json.load(sys.stdin)["projects"][0]; print(p["typical_s"], [c["since"] for c in p["cards"] if c["issue"] == 7])')"
assert_contains "$got" "{'develop': 60} ['2026-10-09T11:30:00-03:00']"
rm "$P/logs/2026-10-09-7-develop.log" "$P/board.tsv"

# a live run tells its step (as its place among the stage's steps) and the last things its session did
mkdir -p "$P/locks/validate-9.lock"; printf '1 1791600000 9\n' > "$P/locks/validate-9.lock/info"; printf '3\t1791600300\n' > "$P/locks/validate-9.lock/step"
{ cmd '"<command-name>/sf:validate</command-name>\n<command-args>9</command-args>"'
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
' '{"type":"user","timestamp":"not a time","message":{"content":"<command-name>/sf:develop</command-name><command-args>8</command-args>"}}' > "$T/bad.jsonl"
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
{ cmd '"<command-name>/sf:develop</command-name>\n<command-args>11</command-args>"'
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-09T10:01:00Z","message":{"content":[{"type":"text","text":"Planning the work."},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
  printf '{"type":"attachment","timestamp":"2026-10-09T10:02:00Z","attachment":{"type":"hook_additional_context","content":["%s\\n\\nuse the old header"]}}\n' "$intro"; } > "$T/s4.jsonl"
live() { curl -s -H "$H_TOK" "$base/api/live/shop/11" | $PY -c 'import json,sys; s=json.load(sys.stdin); print(s["running"], [(e["kind"], e["text"]) for e in s["events"]], "pending", [m["text"] for m in s["pending"]])'; }
assert_contains "$(live)" "True [('says', 'Planning the work.'), ('Bash', 'ls'), ('owner', 'use the old header')] pending []"
[ "$(post -d '{"text":"keep the footer"}' "$base/api/card/shop/11/message")" = 403 ] && pass "no token, no message" || fail "took a message without the token"
[ "$(post -d '{"text":"keep the footer"}' "$base/api/card/shop/7/message" -H "$H_TOK")" = 409 ] && pass "no run, no message" || fail "took a message for a card nobody works on"
[ "$(post -d '{"text":" "}' "$base/api/card/shop/11/message" -H "$H_TOK")" = 400 ] && pass "an empty message is refused" || fail "took an empty message"
[ "$(post -d '{"text":"keep the \"footer\""}' "$base/api/card/shop/11/message" -H "$H_TOK")" = 200 ] && pass "message queued" || fail "message failed"
assert_contains "$(live)" "pending ['keep the \"footer\"']"
hook() { echo "$1" | SHIPFLOOR_RUN_LOCK="$(nat "$L")" bash "$FACTORY_DIR/inbox-hook.sh" | $PY -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "nothing")'; }
assert_contains "$(hook '{}')" 'keep the "footer"'
assert_contains "$(hook '{}')" "nothing"
assert_contains "$(hook '{"agent_id":"a1"}')" 'keep the "footer"'
assert_contains "$(live)" "pending []"
assert_contains "$(echo '{}' | SHIPFLOOR_RUN_LOCK="$(nat "$P/locks/none.lock")" bash "$FACTORY_DIR/inbox-hook.sh"; echo "rc=$?")" "rc=0"
# the decision inbox: what the owner reads to decide (the spec from the review page, the block told in parts),
# and the two decisions a block adds to unblock: take the acceptance tests as they stand, or send the card back
printf '%s\n' '<script>const S=[{"id":"open-questions","t":"Open questions","intro":"","items":["Keep the old header?"],"ro":false},{"id":"product","t":"Product","intro":"","items":["Problem: the header is cut.","AC-1: Given a phone, Then the header fits.","AC-2 Given a tablet, Then it fits too."],"ro":true}];' '</script>' > "$P/reviews/7.html"
# (GitHub lists comments oldest first: the note of the newest block wins over an older one and over the stage's report)
printf '%s\n' '[{"body":"Validate blocked before"},{"body":"Factory validate, step 2 (gates): blocked.\nacceptance-intact failed: a test changed.\nTried: a diff of the files."},{"body":"## Factory report: validate, outcome blocked"}]' > "$FAKE_GH_DIR/issue-comments"
got="$(curl -s -H "$H_TOK" "$base/api/decide/shop/7" | $PY -c 'import json,sys; d=json.load(sys.stdin); s, b = d["spec"], d["block"]; print(s["problem"], [c["id"] for c in s["criteria"]], s["questions"], b["stage"], b["step"], b["times"], b["gate"], "|", b["why"], "|", b["tried"])')"
assert_contains "$got" "the header is cut. ['AC-1', 'AC-2'] ['Keep the old header?'] validate 2 0 acceptance-intact | acceptance-intact failed: a test changed. | a diff of the files."
[ "$(code "$base/api/decide/shop/7")" = 403 ] && pass "no token, no decision data" || fail "served the decision data without the token"
[ "$(post -d '{"text":""}' "$base/api/card/shop/7/accept" -H "$H_TOK")" = 400 ] && pass "accepting the tests needs a reason" || fail "accepted without a reason"
[ "$(post -d '{"text":"the label changed"}' "$base/api/card/shop/7/accept" -H "$H_TOK")" = 502 ] && pass "a failed accept leaves the card blocked" || fail "accept without a worktree did not fail"
[ "$(post -d '{"text":"restore the test"}' "$base/api/card/shop/8/send-back" -H "$H_TOK")" = 409 ] && pass "only a blocked card is sent back" || fail "sent back a card that is not blocked"
[ "$(post -d '{"text":" "}' "$base/api/card/shop/7/send-back" -H "$H_TOK")" = 400 ] && pass "sending back needs a note" || fail "sent back without a note"
: > "$FAKE_GH_DIR/calls"
[ "$(post -d '{"text":"restore the test"}' "$base/api/card/shop/7/send-back" -H "$H_TOK")" = 200 ] && pass "sent back to Coding" || fail "send-back failed"
assert_contains "$(cat "$FAKE_GH_DIR/comments")" "restore the test"
assert_contains "$(tr '\n' '|' < "$FAKE_GH_DIR/calls")" "issue comment 7 --repo acme/shop --body-file -|"
assert_contains "$(cat "$FAKE_GH_DIR/calls")" "--id PVTI_7 --field-id FLD_x --single-select-option-id opt6"
assert_contains "$(cat "$FAKE_GH_DIR/calls")" "api -X DELETE repos/acme/shop/issues/7/labels/blocked"
# an approval may carry a note (the answer to a spec's open question): it is posted on the issue
[ "$(post -d '{"column":"Staged","text":"yes, keep it"}' "$base/api/card/shop/9/approve" -H "$H_TOK")" = 200 ] && pass "approved with a note" || fail "approve with a note failed"
assert_contains "$(cat "$FAKE_GH_DIR/comments")" "yes, keep it"
rm "$FAKE_GH_DIR/issue-comments"
# settings: this machine's limits are read with their defaults and written all at once, checked together;
# what else config.yml holds stays; a pause is the PAUSE file `shipfloor pause` writes
printf 'pool: 6\nlanguage: pt-BR\nstages:\n  develop: 3\n' > "$H/config.yml"
sget() { curl -s -H "$H_TOK" "$base/api/settings" | $PY -c 'import json,sys; s=json.load(sys.stdin); m=s["machine"]; p=s["projects"][0]; print(m["pool"], m["stages"]["develop"], m["stages"]["refine"], m["stacks"], s["paused"], p["slug"], p["paused"], p["repo"], [l["name"] for l in p["layers"]])'; }
assert_contains "$(sget)" "6 3 2 3 False shop False acme/shop ["
[ "$(code "$base/api/settings")" = 403 ] && pass "no token, no settings" || fail "served the settings without the token"
[ "$(post -d '{"pool":2,"stages":{"develop":3}}' "$base/api/settings/machine" -H "$H_TOK")" = 400 ] && pass "a stage above the pool is refused" || fail "took a stage above the pool"
assert_contains "$(cat "$H/config.yml")" "pool: 6"
[ "$(post -d '{"pool":4}' "$base/api/settings/machine")" = 403 ] && pass "no token, no change" || fail "changed the settings without the token"
[ "$(post -d '{"pool":8,"stages":{"develop":4,"validate":1},"stacks":2}' "$base/api/settings/machine" -H "$H_TOK")" = 200 ] && pass "limits saved" || fail "saving the limits failed"
assert_contains "$(sget)" "8 4 2 2 False shop"
assert_contains "$(tr '\n' ' ' < "$H/config.yml")" "language: pt-BR"
[ "$(post -d '{"paused":true}' "$base/api/settings/pause" -H "$H_TOK")" = 200 ] && [ -e "$H/PAUSE" ] && pass "factory paused" || fail "pause failed"
[ "$(post -d '{"project":"shop","paused":true}' "$base/api/settings/pause" -H "$H_TOK")" = 200 ] && [ -e "$P/PAUSE" ] && pass "project paused" || fail "project pause failed"
assert_contains "$(sget)" "8 4 2 2 True shop True"
[ "$(post -d '{"project":"nope","paused":true}' "$base/api/settings/pause" -H "$H_TOK")" = 404 ] && pass "no such project to pause" || fail "paused an unknown project"
post -d '{"paused":false}' "$base/api/settings/pause" -H "$H_TOK" >/dev/null; post -d '{"project":"shop","paused":false}' "$base/api/settings/pause" -H "$H_TOK" >/dev/null
[ ! -e "$H/PAUSE" ] && [ ! -e "$P/PAUSE" ] && pass "resumed" || fail "resume failed"
rm "$H/config.yml"
# a project's operational limits can be set on this machine: kept in overrides.yml beside the project's config,
# laid over factory.yml by every config reader, and gone again when the owner goes back to the repository's value
knobs() { curl -s -H "$H_TOK" "$base/api/settings" | $PY -c 'import json,sys; k=json.load(sys.stdin)["projects"][0]["knobs"]; print(k["limits.develop.wip"]["value"], k["limits.develop.wip"]["repo"], k["deploy.timeout_min"]["value"], k["deploy.timeout_min"]["repo"])'; }
was="$(knobs)"; wip_repo="${was%% *}"
cfgget() { FACTORY_CONFIG="$P/factory.yml" bash "$FACTORY_DIR/shipfloor-config.sh" get "$1" | tr -d '\r'; }
[ "$(post -d '{"project":"shop","values":{"limits.develop.wip":9,"deploy.timeout_min":45}}' "$base/api/settings/project" -H "$H_TOK")" = 200 ] && pass "project limits overridden" || fail "overriding the project limits failed"
assert_contains "$(knobs)" "9 $wip_repo 45 "
assert_contains "wip=$(cfgget limits.develop.wip) timeout=$(cfgget deploy.timeout_min)" "wip=9 timeout=45"
[ "$(post -d '{"project":"shop","values":{"limits.develop.wip":-1}}' "$base/api/settings/project" -H "$H_TOK")" = 400 ] && pass "a negative limit is refused" || fail "took a negative limit"
[ "$(post -d '{"project":"shop","values":{"project.repo":"x/y"}}' "$base/api/settings/project" -H "$H_TOK")" = 400 ] && pass "only the operational limits can be overridden" || fail "overrode something else"
[ "$(post -d '{"project":"shop","values":{"limits.develop.wip":3}}' "$base/api/settings/project")" = 403 ] && pass "no token, no override" || fail "overrode without the token"
printf 'layers: []\n' > "$P/overrides.yml.bad"; cp "$P/overrides.yml" "$P/overrides.yml.keep"; cp "$P/overrides.yml.bad" "$P/overrides.yml"
assert_contains "$(FACTORY_CONFIG="$P/factory.yml" bash "$FACTORY_DIR/shipfloor-config.sh" validate 2>&1 || true)" "overrides.yml: layers cannot be overridden"
cp "$P/overrides.yml.keep" "$P/overrides.yml"; rm "$P/overrides.yml.bad" "$P/overrides.yml.keep"
[ "$(post -d '{"project":"shop","values":{"limits.develop.wip":null,"deploy.timeout_min":null}}' "$base/api/settings/project" -H "$H_TOK")" = 200 ] && [ ! -e "$P/overrides.yml" ] && pass "back to the repository's values" || fail "the overrides were not removed"
assert_contains "$(knobs)" "$was"
# the overview lists the runs that ended today, newest first (the Today panel), and the deploy script's own
# lock inside a deploy run is not a second run
printf '== start /sf:refine 12 %sT08:00:00-03:00 pid=1
== end /sf:refine 12 exit=0 %sT08:09:00-03:00
== start /sf:refine 12 %sT09:00:00-03:00 pid=2
== end /sf:refine 12 exit=3 %sT09:01:00-03:00
' "$D" "$D" "$D" "$D" > "$P/logs/$D-12-refine.log"
mkdir -p "$P/locks/deploysh-11.lock"; echo "1 $(date +%s) 11" > "$P/locks/deploysh-11.lock/info"
got="$(curl -s -H "$H_TOK" "$base/api/overview" | $PY -c 'import json,sys; o=json.load(sys.stdin); print([(r["issue"], r["stage"], r["exit"], r["cost"]) for r in o["projects"][0]["ended"]], sorted({r["stage"] for r in o["runs"]}))')"
assert_contains "$got" "[(12, 'refine', 3, None), (12, 'refine', 0, None)] ['develop']"

# the review iframe holds the panel color until its page has the theme (#12): no white, no other theme's palette
printf '<!doctype html><html><head><title>spec</title></head><body><p>spec</p></body></html>\n' > "$P/reviews/21.html"
printf '<p>a hand-written page, no head</p>\n' > "$P/reviews/22.html"
shell="$(curl -s "$base/?t=$tok" | tr -d '\r' | tr '\n' ' ')"
rule() { printf '%s' "$shell" | grep -o "$1" | head -n 1; }   # rule SELECTOR-REGEX: the first rule block, one line
base_rule="$(rule '[ }]iframe *{[^}]*}')"
themed_rule="$(rule 'iframe\.themed[^{]*{[^}]*}')"
plain_rule="$(rule 'iframe\.plain[^{]*{[^}]*}')"
embed="$(curl -s "$base/review/shop/21?embed=1&t=$tok" | tr -d '\r')"
pos() { local s="${1%%"$2"*}"; [ "$s" = "$1" ] && echo -1 || echo "${#s}"; }  # pos TEXT NEEDLE: offset of the first NEEDLE, -1 if absent
# AC-1: from the click until the page is shown, the review area is the panel color and never white
case "$base_rule" in *"background: var(--panel)"*) pass "AC-1 the iframe holds the panel color before the page is shown" ;; *) fail "AC-1 the base iframe rule must be 'background: var(--panel)', got: $base_rule" ;; esac
case "$base_rule" in *"visibility: hidden"*) pass "AC-1 the iframe paints nothing of the page until it is themed" ;; *) fail "AC-1 the base iframe rule must hide the page ('visibility: hidden') until it is themed, got: $base_rule" ;; esac
case "$base_rule" in *"#fff"*|*"#ffffff"*|*"white"*) fail "AC-1 the base iframe rule must not hold white, got: $base_rule" ;; *) [ -n "$base_rule" ] && pass "AC-1 no white in the base iframe rule" || fail "AC-1 the iframe rule is missing from GET /" ;; esac
case "$base_rule" in *"display: none"*|*"display:none"*) fail "AC-1 the iframe keeps its box while held (no display: none), got: $base_rule" ;; *) pass "AC-1 the held iframe keeps its box" ;; esac
case "$themed_rule" in *"visibility: visible"*|*"visibility:visible"*) pass "AC-1 .themed shows the page" ;; *) fail "AC-1 an 'iframe.themed' rule with 'visibility: visible' must show the themed page, got: $themed_rule" ;; esac
# AC-2: the theme reaches the page before it paints, and the dashboard reveals on the acknowledgement, not on "ready"
r="$(pos "$embed" 'shipfloor:"ready"')"; l="$(pos "$embed" 'addEventListener("load"')"; m="$(pos "$embed" 'addEventListener("message"')"
[ "$r" -ge 0 ] && [ "$l" -ge 0 ] && [ "$r" -lt "$l" ] && pass "AC-2 'ready' is posted before the load handler" || fail "AC-2 the embed script must post shipfloor:\"ready\" (at $r) before addEventListener(\"load\" (at $l), when it is parsed in <head>"
[ "$m" -ge 0 ] && [ "$m" -lt "$r" ] && pass "AC-2 the theme listener is registered before 'ready'" || fail "AC-2 the embed script must register its 'message' listener (at $m) before it posts 'ready' (at $r)"
case "$embed" in *'shipfloor:"themed"'*) pass "AC-2 the embed script posts 'themed'" ;; *) fail "AC-2 the embed script must post shipfloor:\"themed\" after applying each theme message" ;; esac
case "$embed" in *'shipfloor:"review-progress"'*) [ "$(pos "$embed" 'shipfloor:"review-progress"')" -gt "$l" ] && pass "AC-2 review-progress stays in the load handler" || fail "AC-2 review-progress must stay inside the load handler" ;; *) fail "AC-2 the embed script lost its review-progress message" ;; esac
printf '%s' "$shell" | grep -Eq 'shipfloor *=== *"themed"' && pass "AC-2 the dashboard listens for 'themed'" || fail "AC-2 the dashboard must reveal the page on the 'themed' message (m.shipfloor === \"themed\")"
printf '%s' "$shell" | grep -Eq 'shipfloor *=== *"ready"[^;]*classList' && fail "AC-2 the dashboard must not reveal the page on 'ready'" || pass "AC-2 'ready' does not reveal the page"
# AC-3: a page that does not take the embed theme is shown on white once its load ends, as today
case "$plain_rule" in *"#fff"*) pass "AC-3 .plain carries #fff" ;; *) fail "AC-3 an 'iframe.plain' rule with 'background: #fff' must show a plain page, got: $plain_rule" ;; esac
printf '%s' "$shell" | grep -Eq 'addEventListener\( *"load"' && printf '%s' "$shell" | grep -Eq 'classList\.(add|toggle)\( *"plain"' && pass "AC-3 .plain is set from the load path" || fail "AC-3 the dashboard must set .plain from a load listener on #pane when no 'ready' came"
[ "$(curl -s "$base/review/shop/22?embed=1&t=$tok" | tr -d '\r')" = "$(tr -d '\r' < "$P/reviews/22.html")" ] && pass "AC-3 a page without </head> is returned unchanged" || fail "AC-3 a page without </head> must come back byte for byte on ?embed=1"
[ "$(curl -s "$base/review/shop/21?t=$tok" | tr -d '\r')" = "$(tr -d '\r' < "$P/reviews/21.html")" ] && pass "AC-3 without embed=1 the bytes are the file's" || fail "AC-3 a page requested without embed=1 must be the file's bytes"
# AC-4: every opening is a new iframe element in the held state, whatever card or how often
case "$shell" in *'src="/review/${encodeURIComponent(p)}/${n}?embed=1&t='*) pass "AC-4 reviewPane builds the iframe afresh" ;; *) fail "AC-4 reviewPane must build the iframe element" ;; esac
case "$shell" in *'<iframe class='*|*'<iframe title="Review page for #${esc(n)}" class='*) fail "AC-4 the state classes live in the DOM only, never in reviewPane's HTML" ;; *) pass "AC-4 reviewPane's HTML carries no state class" ;; esac
case "$base_rule" in *"visibility: hidden"*"background: var(--panel)"*|*"background: var(--panel)"*"visibility: hidden"*) pass "AC-4 a new iframe starts held on the panel color" ;; *) fail "AC-4 a new iframe must start held (hidden, on var(--panel)) at every opening, got: $base_rule" ;; esac
# AC-5: a themed page looks as today: the embed <style> block is byte for byte what it was
want_css="$(printf '%s\n' '<style>' 'header.top{display:none}' \
  'html:root:not([data-x]){--page:#0d1014;--sheet:#151a21;--surface:#1b212a;--ink:#ebe5d5;--muted:#8f8b80;--rule:#262e39;' \
  '--linen:#262e39;--linen-ink:#ebe5d5;--display:"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;--body:var(--display)}' \
  '@media (prefers-color-scheme:light){html:root:not([data-x]){--page:#e7e7e4;--sheet:#f4f4f2;--surface:#ececea;--ink:#23262b;' \
  '--muted:#6b6a66;--rule:#d9d9d4;--linen:#d9d9d4;--linen-ink:#23262b}}' \
  'h1,section h2{font-weight:600}' 'section h2{font-size:17px;line-height:1.3}' '.count{display:none}' \
  'button{background:transparent;color:var(--ink);border-color:var(--rule)}' '</style>')"
assert_contains "$embed" "$want_css"
assert_contains "$embed" '<p>spec</p></body>'
case "$embed" in *'--page:#0d1014'*'</style>'*'<script>'*'</script></head>'*) pass "AC-5 the style block, then the script, then </head>" ;; *) fail "AC-5 the embed response must be <style>, <script>, then </head>" ;; esac
# AC-5 (red now): the page still gets every color the theme sends, and acknowledges them once applied
case "$embed" in *'r.style.setProperty("--"+k,m.vars[k])'*'shipfloor:"themed"'*) pass "AC-5 the theme is applied to the root, then 'themed' is posted" ;; *) fail "AC-5 the embed script must apply the theme vars to the root and only then post shipfloor:\"themed\"" ;; esac
# AC-6: no review page, or none that arrives: the empty area is the panel color, not white
printf '%s' "$shell" | grep -Fq "c.review ? \`<iframe" && printf '%s' "$shell" | grep -Fq "</iframe>\` : '<p class=\"placeholder\">No review page for this card. Refine builds it when the spec is ready.</p>'" && pass "AC-6 no review page renders the placeholder paragraph and no iframe" || fail "AC-6 reviewPane must render the .placeholder paragraph, and no iframe, when the card has no review page"
case "$base_rule" in *"background: var(--panel)"*) pass "AC-6 an iframe whose document never arrives stays on the panel color" ;; *) fail "AC-6 the iframe must stay on var(--panel) while no document arrives, got: $base_rule" ;; esac
# working hours: the overview and the settings carry `hours`, and Settings writes it. The dashboard reads the clock in its own
# process, so each clock is a server of its own: one at 23:30 (outside 08:00-23:00) and one at 12:00 (inside)
SRVS=""
start_at() {  # start_at <HH:MM> <out file>: a dashboard whose clock says <HH:MM>
  SHIPFLOOR_NOW="$1" $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$2" 2>&1 &
  SRVS="$SRVS $!"
  for _ in $(seq 1 50); do grep -qs 'http://' "$2" && break; sleep 0.1; done
}
trap 'kill $srv $srv2 $SRVS 2>/dev/null' EXIT
start_at 23:30 "$FAKE_GH_DIR/out-late"; url_late="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out-late")"; base_late="${url_late%%/?t=*}"; H_LATE="X-Shipfloor-Token: ${url_late##*t=}"
start_at 12:00 "$FAKE_GH_DIR/out-noon"; url_noon="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out-noon")"; base_noon="${url_noon%%/?t=*}"; H_NOON="X-Shipfloor-Token: ${url_noon##*t=}"
hours_of() {  # hours_of <base> <token header> <overview|settings>: the hours object as the API gives it
  curl -s -H "$2" "$1/api/$3" | $PY -c 'import json,sys; h=(json.load(sys.stdin).get("hours") or {}); print(h.get("windows"), h.get("open"), h.get("next"), h.get("error") is not None)' 2>&1
}
cfg_hours() { $PY -I -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print(json.dumps(d.get("hours", "<unset>")))' "$(nat "$H/config.yml")" | tr -d '\r'; }
cfg_other() { $PY -I -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; d.pop("hours", None); print(json.dumps(d, sort_keys=True))' "$(nat "$H/config.yml")" | tr -d '\r'; }

# AC-4 the overview and the settings say whether the factory is outside its hours and when the next window starts
printf 'hours: ["08:00-23:00"]\n' > "$H/config.yml"
assert_contains "$(hours_of "$base_late" "$H_LATE" overview)" "['08:00-23:00'] False 08:00 False"
assert_contains "$(hours_of "$base_late" "$H_LATE" settings)" "['08:00-23:00'] False 08:00 False"
assert_contains "$(hours_of "$base_noon" "$H_NOON" overview)" "['08:00-23:00'] True None False"
assert_contains "$(hours_of "$base_noon" "$H_NOON" settings)" "['08:00-23:00'] True None False"
printf 'hours: ["08:00-23:00", "20:00-04:00"]\n' > "$H/config.yml"
assert_contains "$(hours_of "$base_late" "$H_LATE" overview)" "['08:00-23:00', '20:00-04:00'] True None False"
# AC-8 unset: always open, no message
rm "$H/config.yml"
assert_contains "$(hours_of "$base_late" "$H_LATE" overview)" "[] True None False"
assert_contains "$(hours_of "$base_late" "$H_LATE" settings)" "[] True None False"
# AC-5 malformed in config.yml: open at all hours, the error and the value as written go to the page
printf 'hours: ["8-23"]\n' > "$H/config.yml"
assert_contains "$(hours_of "$base_late" "$H_LATE" overview)" "['8-23'] True None True"
assert_contains "$(hours_of "$base_late" "$H_LATE" settings)" "['8-23'] True None True"
rm "$H/config.yml"

# AC-7 Settings sets, changes and clears the window; the rest of config.yml stays; a malformed value is refused and writes nothing
printf 'pool: 6\nlanguage: pt-BR\nstages:\n  develop: 3\n' > "$H/config.yml"
rest_before="$(cfg_other)"
mpost() { curl -s -o "$FAKE_GH_DIR/mbody" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_LATE" -d "$1" "$base_late/api/settings/machine"; }
got="$(mpost '{"hours":["08:00-23:00","20:00-04:00"]}')"
[ "$got" = 200 ] && pass "AC-7 setting hours is accepted" || fail "AC-7 setting hours answered $got: $(cat "$FAKE_GH_DIR/mbody")"
[ "$(cfg_hours)" = '["08:00-23:00", "20:00-04:00"]' ] && pass "AC-7 config.yml holds exactly the windows set" || fail "AC-7 hours in config.yml: $(cfg_hours)"
[ "$(cfg_other)" = "$rest_before" ] && pass "AC-7 the other keys of config.yml keep their values" || fail "AC-7 config.yml changed elsewhere: $(cfg_other), was $rest_before"
assert_contains "$(hours_of "$base_late" "$H_LATE" settings)" "['08:00-23:00', '20:00-04:00'] True None False"
got="$(mpost '{"hours":["09:00-17:00"]}')"
[ "$got" = 200 ] && [ "$(cfg_hours)" = '["09:00-17:00"]' ] && pass "AC-7 changing hours replaces the windows" || fail "AC-7 change answered $got, hours in config.yml: $(cfg_hours)"
assert_contains "$(hours_of "$base_late" "$H_LATE" settings)" "['09:00-17:00'] False 09:00 False"
assert_contains "$(SHIPFLOOR_NOW=23:30 bash -c "source '$FACTORY_DIR/lib/project.sh'; shipfloor_machine hours" | tr -d '\r')" "closed 09:00"
cp "$H/config.yml" "$FAKE_GH_DIR/config.saved"
for badv in '["25:00-26:00"]' '["8-23"]' '["08:00-08:00"]' '["08:00-23:00", ""]' '["09:00-17:00", "nine-five"]'; do
  got="$(mpost "{\"hours\":$badv}")"
  [ "$got" = 400 ] && pass "AC-7 $badv is refused with 400" || fail "AC-7 $badv answered $got, want 400"
  assert_contains "$(cat "$FAKE_GH_DIR/mbody")" '"error"'
  assert_contains "$(cat "$FAKE_GH_DIR/mbody")" "hours"
  cmp -s "$H/config.yml" "$FAKE_GH_DIR/config.saved" && pass "AC-7 $badv writes nothing" || fail "AC-7 $badv changed config.yml"
done
[ "$(post -d '{"hours":["01:00-02:00"]}' "$base_late/api/settings/machine")" = 403 ] && cmp -s "$H/config.yml" "$FAKE_GH_DIR/config.saved" && pass "AC-7 no token, no change of hours" || fail "AC-7 hours changed without the token"
got="$(mpost '{"hours":null}')"
[ "$got" = 200 ] && [ "$(cfg_hours)" = '"<unset>"' ] && pass "AC-7 null clears hours: the key is removed" || fail "AC-7 null answered $got, hours in config.yml: $(cfg_hours)"
[ "$(cfg_other)" = "$rest_before" ] && pass "AC-7 clearing keeps the other keys" || fail "AC-7 clearing changed config.yml elsewhere: $(cfg_other)"
assert_contains "$(hours_of "$base_late" "$H_LATE" settings)" "[] True None False"
mpost '{"hours":["09:00-17:00"]}' >/dev/null
got="$(mpost '{"hours":[]}')"
[ "$got" = 200 ] && [ "$(cfg_hours)" = '"<unset>"' ] && pass "AC-7 an empty list clears hours: the key is removed" || fail "AC-7 [] answered $got, hours in config.yml: $(cfg_hours)"
got="$(mpost '{"pool":7}')"
[ "$got" = 200 ] && assert_contains "$(cfg_other)" '"pool": 7' && [ "$(cfg_hours)" = '"<unset>"' ] || fail "AC-7 saving only the pool answered $got: $(cat "$FAKE_GH_DIR/mbody")"
printf 'pool: 6\nhours: ["09:00-17:00"]\n' > "$H/config.yml"
got="$(mpost '{"pool":7}')"
[ "$got" = 200 ] && [ "$(cfg_hours)" = '["09:00-17:00"]' ] && pass "AC-7 saving the pool leaves hours as it was" || fail "AC-7 saving the pool answered $got and left hours at $(cfg_hours)"
rm "$H/config.yml"

# AC-4 / AC-7 the page: the copy and the control are in dashboard.html, the translations in dashboard.pt-BR.json
html="$FACTORY_DIR/dashboard.html"
for s in 'Outside working hours:' 'starts again at' 'Working hours' 'placeholder="always"' 'spellcheck="false"' 'autocomplete="off"' 'aria-invalid' \
         'Windows like 08:00-23:00, separated by commas. Empty means always.' \
         'Working hours not saved: write each window as HH:MM-HH:MM, separated by commas.' \
         'The hours in config.yml are not valid, so the dispatcher runs at all hours.' '.disp.idle .sdot'; do
  grep -qF -- "$s" "$html" && pass "AC-4/AC-7 dashboard.html has '$s'" || fail "AC-4/AC-7 dashboard.html lacks '$s'"
done
cat > "$FAKE_GH_DIR/catalog.py" <<'EOP'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ex, rx = d.get("exact", {}), [tuple(x) for x in d.get("rx", [])]
want = {
    "Outside working hours:": "Fora do hor\u00e1rio de trabalho:",
    "Working hours": "Hor\u00e1rio de trabalho",
    "always": "sempre",
    "Windows like 08:00-23:00, separated by commas. Empty means always.": "Janelas como 08:00-23:00, separadas por v\u00edrgula. Vazio significa sempre.",
    "Working hours not saved: write each window as HH:MM-HH:MM, separated by commas.": "Hor\u00e1rio de trabalho n\u00e3o salvo: escreva cada janela como HH:MM-HH:MM, separadas por v\u00edrgula.",
    "The hours in config.yml are not valid, so the dispatcher runs at all hours.": "O hor\u00e1rio em config.yml n\u00e3o \u00e9 v\u00e1lido, ent\u00e3o o dispatcher roda a qualquer hora.",
}
for k, v in want.items():
    print("ok" if ex.get(k) == v else "MISSING exact: " + k.encode("ascii", "replace").decode())
print("ok" if (r"starts again at (\d\d:\d\d)", "volta a iniciar \u00e0s $1") in rx else "MISSING rx: starts again at (\\d\\d:\\d\\d)")
EOP
while IFS= read -r line; do
  line="${line%$'\r'}"
  [ "$line" = ok ] && pass "AC-4/AC-7 pt-BR catalog entry" || fail "AC-4/AC-7 dashboard.pt-BR.json: $line"
done < <($PY -I "$(nat "$FAKE_GH_DIR/catalog.py")" "$(nat "$FACTORY_DIR/lang/dashboard.pt-BR.json")" 2>&1)
finish
