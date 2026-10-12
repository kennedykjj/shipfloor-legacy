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
printf '%sT10:00:00-03:00 shipfloor: shop: first\nmv: stderr\n%sT10:10:00-03:00 shipfloor: shop: last\n' "$D" "$D" > "$H/logs/dispatcher.log"
printf '== start /sf:develop 7 %sT10:05:00-03:00 pid=1\n== end /sf:develop 7 exit=4 %sT10:06:00-03:00\n' "$D" "$D" > "$P/logs/$D-7-develop.log"
got="$(curl -s -H "$H_TOK" "$base/api/feed" | $PY -c 'import json,sys; print(" | ".join(e["text"] + (" exit=%s" % e["exit"] if e.get("issue") else "") for e in json.load(sys.stdin)["events"]))')"
assert_contains "$got" "shipfloor: shop: first | mv: stderr | develop #7 exit=4 | shipfloor: shop: last"
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
finish
