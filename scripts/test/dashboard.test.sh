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
# a line repeated in a row is one event, and a run says what it left behind: the card's title (and no log line: a failed run says why from its report or its exit code)
got="$(curl -s -H "$H_TOK" "$base/api/feed" | $PY -c 'import json,sys; ev=json.load(sys.stdin)["events"]; a=ev[-1]; r=[e for e in ev if e.get("issue")][0]; print(a["n"], a["since"][11:16], a["ts"][11:16], "|", r["stage"], r["title"], "|", "last" in r)')"
assert_contains "$got" "2 10:20 10:23 | develop Seven | False"
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

# ---- cost limits (machine config.yml: costs.card_warn / card_block / day_stop)
# "today" is the machine's local date: do not straddle midnight
[ "$(date +%H%M)" -ge 2358 ] && sleep 150
TODAY="$(date +%F)"; YDAY="$(date -d yesterday +%F)"; TZO="$(date +%:z)"
sess() {  # sess <name> <issue> <model> <input tokens> <day>: a develop session of the card, at noon of that local day
  { printf '{"type":"user","timestamp":"%sT12:00:00%s","message":{"role":"user","content":"<command-name>/sf:develop</command-name>\\n<command-args>%s</command-args>"}}\n' "$5" "$TZO" "$2"
    printf '{"type":"assistant","timestamp":"%sT12:05:00%s","message":{"id":"c-%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":0}}}\n' "$5" "$TZO" "$1" "$3" "$4"; } > "$T/$1.jsonl"
}
ovq() { curl -s -H "$H_TOK" "$base/api/overview" | $PY -c "import json,sys; o=json.load(sys.stdin); c={x['issue']: x for x in o['projects'][0]['cards']}; $1" 2>&1 | tr -d '\r'; }
hs() { grep -qF -- "$1" "$FACTORY_DIR/dashboard.html"; }
ptb() { grep -qF -- "$1" "$FACTORY_DIR/lang/dashboard.pt-BR.json"; }
printf '7\tStaged\n30\tCoding\n' > "$P/board.tsv"

# AC-7: with no costs the overview flags nothing; the three limits read as absent
rm -f "$H/config.yml"
assert_contains "$(ovq 'print(c[7].get("over"), c[30].get("over"))')" "None None"
assert_contains "$(ovq 'k=o.get("costs") or {}; print(k.get("card_warn"), k.get("card_block"), k.get("day_stop"), k.get("day_stopped"))')" "None None None"

# AC-1: card 7 estimate is 24.30 (see above). card_warn 20 flags it; the figure against the limits is total - baseline
printf 'pool: 6\ncosts:\n  card_warn: 20\n  card_block: 40\n  day_stop: 80\n' > "$H/config.yml"
assert_contains "$(ovq 'print(c[7]["over"], round(c[7]["spent"], 2), c[7]["cost"])')" "warn 24.3 24.3"
assert_contains "$(ovq 'k=o["costs"]; print(k["card_warn"], k["card_block"], k["day_stop"], k["day_stopped"])')" "20 40 80 False"
printf 'pool: 6\ncosts:\n  card_warn: 25\n  card_block: 40\n' > "$H/config.yml"
assert_contains "$(ovq 'print(c[7]["over"])')" "None"
printf 'pool: 6\ncosts:\n  card_block: 40\n  day_stop: 80\n' > "$H/config.yml"
assert_contains "$(ovq 'print(c[7]["over"], o["costs"]["card_warn"])')" "None None"   # no card_warn, no flag
# a baseline (the card's estimate at its last cost block) is taken off the figure
printf 'pool: 6\ncosts:\n  card_warn: 14\n  card_block: 40\n' > "$H/config.yml"
mkdir -p "$P/cost"; printf '{"at":"2026-10-09T12:00:00-03:00","limit":40,"total":10,"baseline":0,"stages":{"develop":10}}\n' > "$P/cost/7.json"
assert_contains "$(ovq 'print(c[7]["over"], round(c[7]["spent"], 2), c[7]["cost"])')" "warn 14.3 24.3"   # the marker's total is the next baseline
printf '{"at":"2026-10-09T12:00:00-03:00","limit":40,"total":15,"baseline":0,"stages":{"develop":15}}\n' > "$P/cost/7.json"
assert_contains "$(ovq 'print(c[7]["over"], round(c[7]["spent"], 2), c[7]["cost"])')" "None 9.3 24.3"   # 24.3 in all, but only 9.3 since: under card_warn 14
rm "$P/cost/7.json"
hs "passed the warning set in Settings, Costs" && pass "AC-1 the page has the over-warning flag and its title" || fail "AC-1 no over-warning flag in dashboard.html"
hs "over \$" && pass "AC-1 the flag reads 'over \$N est.'" || fail "AC-1 no 'over \$' flag text in dashboard.html"
hs "over the cost warning" && pass "AC-1 the lifecycle dot says it is over the cost warning" || fail "AC-1 the lifecycle board does not say over the cost warning"
ptb "A estimativa deste card passou do aviso definido em Configurações, Custos. Nada para até o limite de bloqueio." && pass "AC-1 pt-BR title of the flag" || fail "AC-1 pt-BR flag title missing"
ptb "acima do aviso de custo" && pass "AC-1 pt-BR lifecycle dot" || fail "AC-1 pt-BR lifecycle dot missing"

# AC-6: a card that ran on a model with no price has an unknown estimate: never flagged, and its runs add nothing to the day
printf 'pool: 6\ncosts:\n  card_warn: 1\n  card_block: 2\n  day_stop: 5\n' > "$H/config.yml"
sess u30 30 claude-mystery-1 900000000 "$TODAY"
assert_contains "$(ovq 'print(c[30]["cost"], c[30].get("over", "MISSING"), c[30].get("spent", "MISSING"))')" "None None None"
assert_contains "$(ovq 'print(o["today"]["cost"], o["costs"]["day_stopped"])')" "0.0 False"
assert_contains "unpriced=$(curl -s -H "$H_TOK" "$base/api/settings" | $PY -c 'import json,sys; print(json.load(sys.stdin)["unpriced"])' 2>&1 | tr -d '\r')" "unpriced=1"
hs "has no price, so its cost is unknown and the cost limits skip it" && pass "AC-6 the \$ ? title says the limits skip it" || fail "AC-6 the price-missing title is not updated"
hs "on a model with no price" && pass "AC-6 a visible note says cards ran on a model with no price" || fail "AC-6 no visible 'no price' note"
ptb "Um modelo deste card não tem preço, então o custo é desconhecido e os limites de custo não o contam. Adicione em ~/.shipfloor/prices.yml." && pass "AC-6 pt-BR title" || fail "AC-6 pt-BR title missing"
rm "$T/u30.jsonl"

# AC-4: today's estimate across all projects past day_stop stops the day; AC-5: the next local day clears it
printf 'pool: 6\ncosts:\n  day_stop: 80\n' > "$H/config.yml"
sess d21 21 claude-opus-5-5 25000000 "$TODAY"      # US$ 100 today
assert_contains "$(ovq 'k=o["costs"]; print(k["day_stop"], k["day_stopped"])')" "80 True"
sess d21 21 claude-opus-5-5 25000000 "$YDAY"; printf '\n' >> "$T/d21.jsonl"   # the same session, a day earlier
assert_contains "$(ovq 'print(o["costs"]["day_stopped"])')" "False"
printf 'pool: 6\n' > "$H/config.yml"
sess d21 21 claude-opus-5-5 25000000 "$TODAY"
assert_contains "$(ovq 'print(o["costs"].get("day_stopped"))')" "False"           # no day_stop set: never stopped
rm "$T/d21.jsonl"
hs "Runs stopped for today" && pass "AC-4 the alerts line has 'Runs stopped for today'" || fail "AC-4 no day stop alert in dashboard.html"
hs "passed the day limit of" && pass "AC-4 the alert gives today's estimate and the limit" || fail "AC-4 the alert has no explanation"
hs "Sessions already running finish; runs start again tomorrow" && pass "AC-4 the alert says running sessions finish" || fail "AC-4 the alert does not say sessions finish"
hs "Stopped for today by the cost limit" && pass "AC-4 waiting tiles say why" || fail "AC-4 waiting tiles do not say why"
ptb "Execuções paradas por hoje" && pass "AC-4 pt-BR alert title" || fail "AC-4 pt-BR alert missing"
ptb "Parado por hoje pelo limite de custo" && pass "AC-4 pt-BR waiting tile" || fail "AC-4 pt-BR waiting tile missing"

# AC-3: a card blocked by cost reads in the inbox as spend per stage against the limit
unblock7() { post -d '{}' "$base/api/card/shop/7/unblock" -H "$H_TOK" >/dev/null; }   # also drops the dashboard's one-minute caches
dq() { unblock7; curl -s -H "$H_TOK" "$base/api/decide/shop/7" | $PY -c "import json,sys; d=json.load(sys.stdin); b=d['block'] or {}; $1" 2>&1 | tr -d '\r'; }
mkdir -p "$P/cost"; printf '{"at":"2026-10-11T10:00:00-03:00","limit":40,"total":41.2,"baseline":0,"stages":{"develop":30.2,"refine":11}}\n' > "$P/cost/7.json"
printf '%s\n' '[{"body":"Factory validate, step 2 (gates): blocked.\nacceptance-intact failed."},{"body":"Cost limit: blocked.\nEstimated total: $41.20 (estimate), limit $40.00.\n- develop: $30.20\n- refine: $11.00"}]' > "$FAKE_GH_DIR/issue-comments"
assert_contains "$(dq 'print(b.get("kind"), float(b.get("limit") or 0), float(b.get("total") or 0), sorted((k, float(v)) for k, v in (b.get("stages") or {}).items()))')" "cost 40.0 41.2 [('develop', 30.2), ('refine', 11.0)]"
assert_contains "$(dq 'print(b.get("stage"), b.get("step"), bool(b.get("tried")))')" "None None False"
# the marker alone is not enough: the newest block note decides
printf '%s\n' '[{"body":"Cost limit: blocked.\nEstimated total: $41.20 (estimate)"},{"body":"Factory validate, step 2 (gates): blocked.\nacceptance-intact failed."}]' > "$FAKE_GH_DIR/issue-comments"
assert_contains "$(dq 'print(b.get("kind") == "cost")')" "False"
# and a block note without the marker is an ordinary block
printf '%s\n' '[{"body":"Cost limit: blocked.\nEstimated total: $41.20 (estimate)"}]' > "$FAKE_GH_DIR/issue-comments"; rm "$P/cost/7.json"
assert_contains "$(dq 'print(b.get("kind") == "cost")')" "False"
rm "$FAKE_GH_DIR/issue-comments"; rmdir "$P/cost" 2>/dev/null
hs "A card reached its cost limit" && pass "AC-3 the inbox heading for a cost block" || fail "AC-3 no cost block heading"
hs "Blocked · cost limit" && pass "AC-3 the inbox queue meta for a cost block" || fail "AC-3 no cost block queue meta"
hs "since it was last unblocked" && pass "AC-3 the why says the spend is counted from the last unblock" || fail "AC-3 the why does not count from the unblock"
hs "the limit for a card is" && pass "AC-3 the why gives the card limit" || fail "AC-3 the why does not give the limit"
hs "Unblocking lets it spend up to" && pass "AC-3 the hint says what unblocking gives" || fail "AC-3 no unblock hint"
ptb "Um card chegou ao limite de custo" && pass "AC-3 pt-BR heading" || fail "AC-3 pt-BR heading missing"
ptb "Bloqueado · limite de custo" && pass "AC-3 pt-BR queue meta" || fail "AC-3 pt-BR queue meta missing"

# AC-8: the Settings view saves, changes and clears the three limits; bad values are refused
cset() { post -d "$1" "$base/api/settings/machine" -H "$H_TOK"; }
cget() { curl -s -H "$H_TOK" "$base/api/settings" | $PY -c 'import json,sys; c=json.load(sys.stdin)["machine"]["costs"]; print(c["card_warn"], c["card_block"], c["day_stop"])' 2>&1 | tr -d '\r'; }
printf 'pool: 6\nlanguage: pt-BR\n' > "$H/config.yml"
[ "$(cset '{"costs":{"card_warn":20,"card_block":40,"day_stop":80}}')" = 200 ] && pass "AC-8 the three limits are saved" || fail "AC-8 saving the limits failed"
assert_contains "$(tr '\n' ' ' < "$H/config.yml")" "card_warn: 20"
assert_contains "$(tr '\n' ' ' < "$H/config.yml")" "card_block: 40"
assert_contains "$(tr '\n' ' ' < "$H/config.yml")" "day_stop: 80"
assert_contains "$(tr '\n' ' ' < "$H/config.yml")" "pool: 6"
assert_contains "$(tr '\n' ' ' < "$H/config.yml")" "language: pt-BR"
assert_contains "$(cget)" "20 40 80"
[ "$(cset '{"costs":{"card_warn":12.5}}')" = 200 ] && pass "AC-8 one limit changes, with decimals" || fail "AC-8 changing one limit failed"
assert_contains "$(cget)" "12.5 40 80"
[ "$(cset '{"costs":{"day_stop":null}}')" = 200 ] && pass "AC-8 a limit is cleared with null" || fail "AC-8 clearing a limit failed"
assert_contains "$(cget)" "12.5 40 None"
case "$(cat "$H/config.yml")" in *day_stop*) fail "AC-8 a cleared limit is still in config.yml" ;; *) pass "AC-8 a cleared limit leaves config.yml" ;; esac
before="$(cat "$H/config.yml")"
for bad_body in '{"costs":{"card_warn":0}}' '{"costs":{"card_block":-3}}' '{"costs":{"day_stop":"abc"}}' '{"costs":{"day_stop":true}}' \
                '{"costs":{"card_warn":50}}' '{"costs":{"card_block":10}}' '{"costs":{"bogus":5}}'; do
  [ "$(cset "$bad_body")" = 400 ] && pass "AC-8 refused: $bad_body" || fail "AC-8 took $bad_body"
done
[ "$(cat "$H/config.yml")" = "$before" ] && pass "AC-8 refusals change nothing" || fail "AC-8 a refused value reached config.yml"
assert_contains "$(curl -s -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d '{"costs":{"card_warn":50}}' "$base/api/settings/machine")" "card_warn"   # the refusal says which
[ "$(post -d '{"costs":{"day_stop":9}}' "$base/api/settings/machine")" = 403 ] && pass "AC-8 no token, no change" || fail "AC-8 changed the limits without the token"
[ "$(cset '{"costs":{"card_warn":null,"card_block":null}}')" = 200 ] && pass "AC-8 the last limits are cleared" || fail "AC-8 clearing every limit failed"
case "$(cat "$H/config.yml")" in *costs*) fail "AC-8 an empty costs stays in config.yml" ;; *) pass "AC-8 an empty costs is dropped from config.yml" ;; esac
assert_contains "$(cat "$H/config.yml")" "pool: 6"
assert_contains "$(cget)" "None None None"
rm -f "$H/config.yml"
hs "Warn on a card" && hs "Block a card" && hs "Stop the day" && pass "AC-8 the Settings rows exist" || fail "AC-8 the three Settings rows are missing"
hs "limits and the prices behind the estimate" && pass "AC-8 the nav subtitle names the limits" || fail "AC-8 the Costs nav subtitle is not updated"
hs 'inputmode="decimal"' && pass "AC-8 the fields are decimal text fields" || fail "AC-8 no decimal field"
hs "Enter an amount above 0, or leave it empty for no limit." && pass "AC-8 the invalid-amount message" || fail "AC-8 no invalid-amount message"
hs "The warning cannot be above the block" && pass "AC-8 the warn-above-block message" || fail "AC-8 no warn-above-block message"
ptb "Informe um valor acima de 0, ou deixe vazio para sem limite." && pass "AC-8 pt-BR invalid-amount message" || fail "AC-8 pt-BR message missing"
ptb "O aviso não pode ficar acima do bloqueio" && pass "AC-8 pt-BR warn-above-block message" || fail "AC-8 pt-BR warn message missing"
for s in "Avisar em um card" "Bloquear um card" "Parar o dia" "limites e os preços por trás da estimativa"; do
  ptb "$s" && pass "AC-8 pt-BR: $s" || fail "AC-8 pt-BR missing: $s"
done
# --- small hardening (#7): favicon, card numbers that are digits only in ASCII, contrast of the text tokens ---
# AC-1: a browser asks for the favicon without a token; the answer is empty and carries no data
got="$(curl -s -w '|%{http_code}' "$base/favicon.ico")"
[ "$got" = "|204" ] && pass "AC-1 /favicon.ico without a token answers 204 with an empty body" || fail "AC-1 /favicon.ico without a token should answer 204 and nothing else, got '$got'"

# AC-7 (and the base for AC-3/AC-4): card 12 is served for plain ASCII 12 on every route that takes a number
echo '<p>spec 12</p>' > "$P/reviews/12.html"
for r in api/card api/decide api/live; do
  got="$(curl -s -o /dev/null -w '%{http_code}' -H "$H_TOK" "$base/$r/shop/12")"
  [ "$got" = 200 ] && pass "AC-7 /$r/shop/12 still serves card 12" || fail "AC-7 /$r/shop/12 should answer 200, got $got"
done
got="$(curl -s -o /dev/null -w '%{http_code}' -H "$H_TOK" "$base/review/shop/12?t=$tok")"
[ "$got" = 200 ] && pass "AC-7 /review/shop/12 still serves its page" || fail "AC-7 /review/shop/12 should answer 200, got $got"
got="$(curl -s -H "$H_TOK" "$base/api/card/shop/12" | $PY -c 'import json,sys; print(json.load(sys.stdin)["issue"])')"
[ "$got" = 12 ] && pass "AC-7 /api/card/shop/12 returns card 12" || fail "AC-7 /api/card/shop/12 should return issue 12, got '$got'"

# AC-3: Arabic-Indic 12 (percent-encoded) is not card 12
got="$(curl -s -w '|%{http_code}' -H "$H_TOK" "$base/api/card/shop/%D9%A1%D9%A2")"
case "$got" in *'"issue"'*) fail "AC-3 /api/card/shop/١٢ returned card data: $got" ;; *"|404") pass "AC-3 /api/card/shop/١٢ answers 404 with no card data" ;; *) fail "AC-3 /api/card/shop/١٢ should answer 404, got: $got" ;; esac

# AC-4: a segment that passes isdigit() but is not [0-9]+ is a 404 on every GET route that takes a number
for seg in %C2%B2 %D9%A1%D9%A2; do
  for r in api/card api/decide api/live review; do
    got="$(curl -s -o /dev/null -w '%{http_code}' -H "$H_TOK" "$base/$r/shop/$seg?t=$tok")"
    [ "$got" = 404 ] && pass "AC-4 GET /$r/shop/$seg answers 404" || fail "AC-4 GET /$r/shop/$seg should answer 404, got $got"
  done
done

# AC-5: /api/log with a from that is not [0-9]+ answers as a non-numeric from does
printf '0123456789abcdefghijklmnopqrstuvwxyz0123456789\n' > "$P/logs/ac5.log"
logget() { curl -s -w '|%{http_code}' -H "$H_TOK" "$base/api/log/shop/ac5.log?from=$1"; }
want="$(logget abc)"
case "$want" in *"|200") pass "AC-5 from=abc answers 200 (the reference)" ;; *) fail "AC-5 from=abc should answer 200, got: $want" ;; esac
for v in %C2%B2 %D9%A1%D9%A2; do
  got="$(logget "$v")"
  [ "$got" = "$want" ] && pass "AC-5 /api/log?from=$v answers as from=abc" || fail "AC-5 /api/log?from=$v should answer as from=abc ($want), got: $got"
done
rm "$P/logs/ac5.log"

# AC-6: a POST with a card number that is not [0-9]+ gets a 404 (not a dropped connection) and moves nothing.
# The path is sent byte by byte (~b2 stands for the raw Latin-1 byte 0xB2), since curl would rewrite it.
rawpost() {  # rawpost <card segment, ~b2 for the raw byte 0xB2>: the status code, or "dropped" when no answer comes back
  $PY -I - "$base" "$tok" "$1" <<'EOF'
import socket, sys
base, tok, seg = sys.argv[1:4]
host, port = base.rsplit("//", 1)[1].split(":")
raw = b"/api/card/shop/" + seg.replace("~b2", "\xb2").encode("latin-1") + b"/approve"
body = b'{"column":"Spec Review"}'
req = (b"POST " + raw + b" HTTP/1.1\r\nHost: 127.0.0.1:" + port.encode() + b"\r\nContent-Type: application/json\r\nX-Shipfloor-Token: " + tok.encode()
       + b"\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
try:
    s = socket.create_connection((host, int(port)), timeout=5)
    s.sendall(req)
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
except OSError:
    pass
print(data.split(b" ")[1].decode() if data.startswith(b"HTTP/") else "dropped")
EOF
}
before="$(wc -l < "$FAKE_GH_DIR/calls")"
for seg in '%C2%B2' '~b2' '%D9%A1%D9%A2'; do
  got="$(rawpost "$seg" | tr -d '\r')"
  case "$got" in
    404) pass "AC-6 POST /api/card/shop/$seg/approve answers 404" ;;
    dropped) fail "AC-6 POST /api/card/shop/$seg/approve dropped the connection, it should answer 404" ;;
    *) fail "AC-6 POST /api/card/shop/$seg/approve should answer 404, got $got" ;;
  esac
done
after="$(wc -l < "$FAKE_GH_DIR/calls")"
[ "$before" = "$after" ] && pass "AC-6 no board call for a card number that is not [0-9]+" || fail "AC-6 a wrong card number reached the board ($before -> $after calls)"

# AC-8: --soft, --muted and --faint keep 4.5:1 on --panel and --ground in every theme (12 of them).
# A theme inherits what it does not redeclare from :root. Takes the HTML as its argument.
contrast() {
  $PY -I - "$1" <<'EOF'
import re, sys
css = re.sub(r"/\*.*?\*/", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S)
base, themes = {}, {}
for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
    m = re.fullmatch(r'\s*(:root\s*,\s*)?(?:\[data-theme="([\w-]+)"\])?\s*', sel)
    if not m or not (m.group(1) or m.group(2)) or "--ground" not in body:
        continue
    toks = dict(re.findall(r"(--[\w-]+)\s*:\s*([^;]+?)\s*(?:;|$)", body))
    if m.group(1):
        base.update(toks)
    if m.group(2):
        themes[m.group(2)] = toks
def lum(h):
    h = h.lstrip("#")
    h = "".join(c * 2 for c in h) if len(h) == 3 else h[:6]
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def ratio(a, b):
    x, y = sorted((lum(a), lum(b)), reverse=True)
    return (x + 0.05) / (y + 0.05)
for name, t in sorted(themes.items()):
    v = dict(base, **t)
    for tok in ("--soft", "--muted", "--faint"):
        for bg in ("--panel", "--ground"):
            try:
                r = ratio(v[tok], v[bg])
            except (KeyError, ValueError):
                print("FAIL AC-8 %s %s on %s: cannot read the colors (%s, %s)" % (name, tok, bg, v.get(tok), v.get(bg)))
                continue
            print("%s AC-8 %s %s on %s is %.2f:1 (needs 4.5)" % ("ok" if r >= 4.5 else "FAIL", name, tok, bg, r))
print("%s AC-8 found %d themes (needs 12)" % ("ok" if len(themes) == 12 else "FAIL", len(themes)))
EOF
}
while IFS= read -r line; do
  line="${line%$'\r'}"
  case "$line" in ok*) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac
done <<< "$(contrast "$FACTORY_DIR/dashboard.html")"
# the check is real: on a copy (never the repository's file) with a token lowered, or a theme gone, it prints FAIL
M="$(mktemp -d)"
sed 's/--faint: #93928a/--faint: #6a6a6a/' "$FACTORY_DIR/dashboard.html" > "$M/low.html"
assert_contains "$(contrast "$M/low.html" | tr -d '\r' | grep '^FAIL')" "FAIL AC-8 tape --faint on --panel is"
sed 's/--muted: #5c5040/--muted: #8a8a8a/' "$FACTORY_DIR/dashboard.html" > "$M/low-light.html"
assert_contains "$(contrast "$M/low-light.html" | tr -d '\r' | grep '^FAIL')" "FAIL AC-8 kraft --muted on --ground is"
grep -v '^\[data-theme="paper"\]' "$FACTORY_DIR/dashboard.html" > "$M/eleven.html"
assert_contains "$(contrast "$M/eleven.html" | tr -d '\r' | grep '^FAIL')" "FAIL AC-8 found 11 themes (needs 12)"
rm -r "$M"
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
printf '%s' "$shell" | grep -Fq "c.review ? \`<iframe" && printf '%s' "$shell" | grep -Fq "</iframe>\` : noReview(column, c);" && printf '%s' "$shell" | grep -Fq "return '<p class=\"placeholder\">No review page for this card.</p>';" && pass "AC-6 no review page renders the placeholder paragraph and no iframe" || fail "AC-6 reviewPane must render the .placeholder paragraph, and no iframe, when the card has no review page"
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
