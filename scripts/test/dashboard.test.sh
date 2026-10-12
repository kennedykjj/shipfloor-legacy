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
finish
