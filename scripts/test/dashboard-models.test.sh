#!/usr/bin/env bash
# The Settings section "Agents and models" (#34): the models a stage and an agent run on, saved to config.yml,
# the 7-day cost per stage from the transcripts, and the warning for a model with no price.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; C="$(mktemp -d)"; export FAKE_GH_DIR="$(mktemp -d)"
P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
# the fixture project, plus a layer whose agent is the project's own
{ cat "$FACTORY_DIR/test/fixture/factory.yml"; echo "  - {name: docs, path: 'docs/', agent: reviewer, test: 't {selector}', ran: 'ok', tests: ['docs/t/**']}"; } > "$P/factory.yml"
# prices: no entry for fable (nor for the made-up model below)
cat > "$H/prices.yml" <<'EOF'
claude-opus-5-5:   {input: 4.00, output: 20.00, cache_write_5m: 5.00,  cache_write_1h: 8.00,  cache_read: 0.20}
claude-sonnet-5-5: {input: 2.00, output: 10.00, cache_write_5m: 2.50,  cache_write_1h: 4.00,  cache_read: 0.20}
claude-haiku-5-5:  {input: 0.10, output: 0.50,  cache_write_5m: 0.125, cache_write_1h: 0.20,  cache_read: 0.01}
EOF

# Transcripts of the last 7 days and outside them. A card's cost per stage is the sum of its sessions of that stage
# (subagents included); a card with an unpriced session is left out.
T="$C/projects/C--x--shipfloor-projects-shop-control"; mkdir -p "$T"
ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }
IN1='{"input_tokens":1000000,"output_tokens":0}'; OUT1='{"input_tokens":0,"output_tokens":1000000}'
sess() {  # sess <id> <stage> <issue> <days ago> <model> <usage> [<subagent model> <subagent usage>]
  local f="$T/$1.jsonl" ts; ts="$(ago "$4")"
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<command-name>/sf:%s</command-name>\\n<command-args>%s</command-args>"}}\n' "$ts" "$2" "$3" > "$f"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"m-%s","model":"%s","usage":%s}}\n' "$ts" "$1" "$5" "$6" >> "$f"
  if [ -n "${7:-}" ]; then
    mkdir -p "$T/$1/subagents"
    printf '{"type":"assistant","timestamp":"%s","message":{"id":"a-%s","model":"%s","usage":%s}}\n' "$ts" "$1" "$7" "$8" > "$T/$1/subagents/agent-a.jsonl"
  fi
}
sess s21 develop 21 2 claude-sonnet-5-5 "$IN1" claude-sonnet-5-5 "$OUT1"    # card 21: 2.00 + 10.00 = 12.00
sess s22a develop 22 3 claude-sonnet-5-5 "$IN1"                            # card 22: 2.00 + 2.00 = 4.00
sess s22b develop 22 4 claude-sonnet-5-5 "$IN1"
sess s23 develop 23 20 claude-opus-5-5 "$IN1"                              # 20 days ago: outside the window
sess s24 develop 24 1 claude-mystery-1 "$IN1"                              # no price: the card is left out
sess v21 validate 21 2 claude-haiku-5-5 "$IN1"                             # 0.10
sess d25 deploy 25 1 claude-mystery-1 "$IN1"                               # the only deploy in the window is unpriced
sess r26 refine 26 20 claude-opus-5-5 "$IN1"                               # refine: nothing in the window

export CLAUDE_CONFIG_DIR="$(nat "$C")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
H_TOK="X-Shipfloor-Token: $tok"
m() { bash -c "source '$FACTORY_DIR/lib/project.sh'; shipfloor_machine \"\$@\"" _ "$@"; }
sm() { m stage-models 2>&1 | tr '\0' '|'; }
cfgf="$H/config.yml"

# q <python expression over s, the /api/settings body>: its value, or ERR <what went wrong>
q() { curl -s -H "$H_TOK" "$base/api/settings" | $PY -c '
import json, sys
s = json.load(sys.stdin)
try:
    print(eval(sys.argv[1]))
except Exception as e:
    print("ERR", type(e).__name__, e)' "$1" 2>&1; }
# cfg <python expression over c, config.yml loaded>
cfg() { $PY -I -c '
import sys, yaml
c = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print(eval(sys.argv[2]))' "$(nat "$cfgf")" "$1" 2>&1; }
# save <json>: POST to /api/settings/machine; sets CODE and BODY
save() { local out; out="$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d "$1" "$base/api/settings/machine")"; CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"; }
is() {  # is <got> <want> <label>
  [ "$1" = "$2" ] && pass "$3" || fail "$3: got '${1:0:300}', want '$2'"
}

# AC-2 / AC-6: the API lists every stage and agent with today's model as the default
printf 'pool: 6\n' > "$cfgf"
is "$(q 'list(s["models"]["stages"]) == ["refine","develop","validate","deploy"] and s["models"]["choices"] == ["opus","sonnet","haiku","fable"]')" True "AC-6 settings.models lists the choices and the four stages in factory order"
is "$(q '[s["models"]["stages"][k]["default"] for k in ("refine","develop","validate","deploy")]')" "[None, None, 'sonnet', 'sonnet']" "AC-2 the stage defaults are today's models (none for refine and develop)"
is "$(q '[s["models"]["stages"][k]["value"] for k in s["models"]["stages"]]')" "[None, None, None, None]" "AC-2 nothing configured: every stage value is null"
is "$(q 'list(s["models"]["agents"])')" "['product-owner', 'ux-designer', 'qa-engineer', 'engineer', 'cybersec', 'reviewer']" "AC-4 the five plugin agents, then the project's own agent"
is "$(q 's["models"]["agents"]["engineer"]["default"], s["models"]["agents"]["product-owner"]["default"], s["models"]["agents"]["reviewer"]["default"]')" "('sonnet', 'opus', None)" "AC-2 an agent's default is its frontmatter model, a project agent has none"
is "$(q 's["models"]["agents"]["reviewer"]["projects"]')" "[{'project': 'shop', 'layer': 'docs'}]" "AC-4 a project agent lists the project and layer that use it"
is "$(q 's["models"]["problems"]')" "[]" "AC-5 a clean config has no problems"

# AC-7: the average cost per card of the last 7 days, per stage, from the transcripts
is "$(q '(s["models"]["stages"]["develop"]["cost"]["avg"], s["models"]["stages"]["develop"]["cost"]["cards"])')" "(8.0, 2)" "AC-7 develop: cards 21 (12.00) and 22 (4.00) average 8.00; 23 is too old, 24 is unpriced"
is "$(q '(s["models"]["stages"]["validate"]["cost"]["avg"], s["models"]["stages"]["validate"]["cost"]["cards"])')" "(0.1, 1)" "AC-7 validate: one card at 0.10"
for st in refine deploy; do
  is "$(q '(lambda c: c is None or (c["avg"] is None and c["cards"] == 0))(s["models"]["stages"]["'$st'"]["cost"])')" True "AC-7 $st has no priced run in the window: no figure (a null cost, or avg null with 0 cards)"
  is "$(q '(lambda c: c is not None and c["avg"] == 0)(s["models"]["stages"]["'$st'"]["cost"])')" False "AC-7 $st never shows a zero"
done
is "$(q '"agents-cost" if any("cost" in a for a in s["models"]["agents"].values()) else "none"')" "none" "AC-7 agent rows carry no cost"

# AC-6: a change saved in Settings lands in config.yml, the next cycle reads it, the rest of the file stays
save '{"models":{"stages":{"develop":"sonnet"},"agents":{"engineer":"haiku"}}}'
is "$CODE" 200 "AC-6 saving models answers 200"
is "$(cfg 'c["models"]')" "{'stages': {'develop': 'sonnet'}, 'agents': {'engineer': 'haiku'}}" "AC-6 config.yml holds the chosen models"
is "$(cfg 'c["pool"]')" 6 "AC-6 the rest of config.yml stays"
is "$(sm)" "|sonnet|sonnet|sonnet|" "AC-6 the next cycle's stage-models reads the saved develop model"
is "$(q '(s["models"]["stages"]["develop"]["value"], s["models"]["agents"]["engineer"]["value"])')" "('sonnet', 'haiku')" "AC-6 Settings shows the saved values"
save '{"models":{"stages":{"validate":"opus"}}}'
is "$(cfg 'c["models"]')" "{'stages': {'develop': 'sonnet', 'validate': 'opus'}, 'agents': {'engineer': 'haiku'}}" "AC-6 keys not in the request are left as they are"
save '{"models":{"stages":{"develop":null,"validate":null}}}'
is "$CODE" 200 "AC-6 null (Default) answers 200"
is "$(cfg 'c["models"]')" "{'agents': {'engineer': 'haiku'}}" "AC-6 null removes the key and prunes the empty map"
is "$(sm)" "||sonnet|sonnet|" "AC-6 back to today's models for the stages"
save '{"models":{"agents":{"engineer":null}}}'
is "$(cfg '"models" in c')" False "AC-6 no models left: the key is gone from config.yml"

# AC-5: a model the factory does not know, or a name that does not exist, is refused; nothing is written
printf 'pool: 6\nmodels:\n  stages: {develop: haiku}\n' > "$cfgf"; before="$(cat "$cfgf")"
save '{"models":{"agents":{"engineer":"gpt"}}}'
is "$CODE" 400 "AC-5 an unknown model is refused with 400"
case "$BODY" in *engineer*gpt*"is not a model the factory knows. Nothing was saved."*) pass "AC-5 the message names the key and the value" ;; *) fail "AC-5 the 400 does not name key and value: ${BODY:0:300}" ;; esac
is "$(cat "$cfgf")" "$before" "AC-5 a refused save leaves config.yml as it was"
save '{"models":{"stages":{"review":"opus"}}}'
is "$CODE" 400 "AC-5 an unknown stage is refused"
save '{"models":{"agents":{"nobody":"opus"}}}'
is "$CODE" 400 "AC-5 an unknown agent is refused"
save '{"models":{"stages":{"develop":"opus"},"agents":{"engineer":"gpt"}}}'
is "$CODE" 400 "AC-5 one bad row refuses the whole save"
is "$(cat "$cfgf")" "$before" "AC-5 the good row of a refused save is not written either"
save '{"models":{"agents":{"reviewer":"haiku"}}}'
is "$CODE" 200 "AC-4 a project agent a layer names can be saved"
is "$(cfg 'c["models"]["agents"]')" "{'reviewer': 'haiku'}" "AC-4 config.yml holds the project agent's model"
# a value written by hand stays until the owner changes that row; it is shown with its problem and blocks nothing else
printf 'pool: 6\nmodels:\n  agents: {engineer: gpt}\n  stages: {review: opus}\n' > "$cfgf"
is "$(q '(s["models"]["agents"]["engineer"]["value"], [(p["key"], p["value"], p["why"]) for p in s["models"]["problems"]])')" "(None, [('models.agents.engineer', 'gpt', 'model'), ('models.stages.review', 'opus', 'name')])" "AC-5 a hand-written bad entry is a problem, and its row is on Default"
save '{"models":{"stages":{"develop":"haiku"}}}'
is "$CODE" 200 "AC-5 a problem already in the file does not block another row's save"
is "$(cfg 'c["models"]["agents"]["engineer"], c["models"]["stages"]["review"], c["models"]["stages"]["develop"]')" "('gpt', 'opus', 'haiku')" "AC-5 the hand-written entries survive the save"

# AC-8: a model with no price is flagged and can still be saved
rm -f "$cfgf"
save '{"models":{"stages":{"deploy":"fable","develop":"sonnet"},"agents":{"engineer":"fable"}}}'
is "$CODE" 200 "AC-8 a model with no price can still be saved"
is "$(q '(s["models"]["stages"]["deploy"]["value"], s["models"]["stages"]["deploy"]["priced"], s["models"]["agents"]["engineer"]["priced"])')" "('fable', False, False)" "AC-8 fable has no entry in prices.yml: priced is false for the stage and the agent"
is "$(q '(s["models"]["stages"]["develop"]["priced"], s["models"]["stages"]["refine"]["priced"], s["models"]["agents"]["cybersec"]["priced"])')" "(True, True, True)" "AC-8 sonnet is priced; a row on Default is not flagged"

# AC-6 / AC-7 / AC-8: the page carries the section, and the pt-BR catalog has its strings
page="$(curl -s "$base/")"
for s in "Agents and models" "which model runs each role" "models.stages" "models.agents" "Model for " "No priced run in the last 7 days." "cannot be estimated" "which the factory does not know" "is not a stage or an agent here"; do
  case "$page" in *"$s"*) pass "AC-6 the page carries '$s'" ;; *) fail "AC-6 the page has no '$s'" ;; esac
done
got="$($PY -I -c '
import json, re, sys
sys.stdout.reconfigure(encoding="ascii", errors="backslashreplace")
cat = json.load(open(sys.argv[1], encoding="utf-8"))
ex, out = cat["exact"], []
for k, v in {"Agents and models": "Agentes e modelos", "which model runs each role": "qual modelo roda cada papel",
             "No priced run in the last 7 days.": "Nenhuma execu" + chr(231) + chr(227) + "o com pre" + chr(231) + "o nos " + chr(250) + "ltimos 7 dias."}.items():
    out.append("ok" if ex.get(k) == v else "exact %r is %r, want %r" % (k, ex.get(k), v))
def tr(s):
    for pat, to in cat["rx"]:
        s = re.sub(pat, re.sub(r"\$(\d)", r"\\\1", to), s)
    return s
for s, want in (("Model for engineer", "Modelo de engineer"), ("default is Sonnet", "o padr" + chr(227) + "o " + chr(233) + " Sonnet"),
                ("per card " + chr(183) + " 3 cards, last 7 days", "por card"), ("No price for Fable in prices.yml: its cost cannot be estimated.", "Sem pre" + chr(231) + "o para Fable")):
    out.append("ok" if want in tr(s) else "rx: %r comes out %r, want %r in it" % (s, tr(s), want))
print("\n".join(out))' "$(nat "$FACTORY_DIR/lang/dashboard.pt-BR.json")" 2>&1)"
while IFS= read -r line; do
  [ "$line" = ok ] && pass "AC-6 pt-BR catalog entry" || fail "AC-6 pt-BR catalog: $line"
done <<< "$got"
finish
