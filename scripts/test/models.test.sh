#!/usr/bin/env bash
# Which model runs each stage and each agent is ~/.shipfloor/config.yml, not code (#34): the machine config's
# `models` map, the `agent models:` line of describe that the stage skills hand to the Agent tool, and the checks.
source "$(dirname "$0")/lib.sh"
export SHIPFLOOR_HOME="$(mktemp -d)"
CFG="$FACTORY_DIR/shipfloor-config.sh"
M="$FACTORY_DIR/shipfloor"
cfgf="$SHIPFLOOR_HOME/config.yml"
m() { bash -c "source '$FACTORY_DIR/lib/project.sh'; shipfloor_machine \"\$@\"" _ "$@"; }
sm() { m stage-models 2>&1 | tr '\0' '|'; }     # refine|develop|validate|deploy|  (empty = no --model flag)
conf() { printf '%s\n' "$1" > "$cfgf"; }
AC=""   # the AC the checks below belong to, named in every assertion's label
assert_contains() { case "$1" in *"$2"*) pass "$AC contains $2" ;; *) fail "$AC missing '$2' in: $1" ;; esac; }
assert_exit() { local want="$1"; shift; local out got; out="$("$@" 2>&1)"; got=$?; if [ "$got" -eq "$want" ]; then pass "$AC $*"; else fail "$AC $* -> exit $got, want $want: $out"; fi; }

# a project whose layer names an agent of its own, besides the fixture's engineer
PROJ="$(mktemp)"
cat > "$PROJ" <<'EOF'
project: {name: shop, repo: acme/shop}
board: {owner: acme, number: 7}
layers:
  - {name: api, path: 'api/', agent: reviewer, test: 't {selector}', ran: 'ok', tests: ['api/t/**']}
EOF
assert_exit 0 env FACTORY_CONFIG="$PROJ" bash "$CFG" validate
describe() {  # describe [config]: the project's describe, with the machine config of $SHIPFLOOR_HOME beside the projects folder
  FACTORY_CONFIG="${1:-$FACTORY_CONFIG}" FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" bash "$CFG" describe 2>&1
}
no_line() { case "$1" in *"agent models:"*) fail "$2: describe printed an agent models line: $1" ;; *) pass "$2: no agent models line" ;; esac; }

# AC-2: no models key, or a stage left out: the model each run uses today
AC="AC-2"
rm -f "$cfgf"
[ "$(sm)" = "||sonnet|sonnet|" ] && pass "AC-2 no config file: refine and develop keep Claude Code's default, validate and deploy sonnet" || fail "AC-2 no config file: stage-models printed '$(sm)', want '||sonnet|sonnet|'"
conf 'pool: 4'
[ "$(sm)" = "||sonnet|sonnet|" ] && pass "AC-2 no models key: today's models" || fail "AC-2 no models key: stage-models printed '$(sm)', want '||sonnet|sonnet|'"
conf 'models: {}'
[ "$(sm)" = "||sonnet|sonnet|" ] && pass "AC-2 empty models map: today's models" || fail "AC-2 empty models map: stage-models printed '$(sm)', want '||sonnet|sonnet|'"
conf $'models:\n  agents: {engineer: haiku}'
[ "$(sm)" = "||sonnet|sonnet|" ] && pass "AC-2 only agents set: stages keep today's models" || fail "AC-2 only agents set: stage-models printed '$(sm)', want '||sonnet|sonnet|'"
conf $'models:\n  stages: {develop: sonnet}'
[ "$(sm)" = "|sonnet|sonnet|sonnet|" ] && pass "AC-2 a stage left out keeps its model, the one set changes" || fail "AC-2 develop: sonnet: stage-models printed '$(sm)', want '|sonnet|sonnet|sonnet|'"
conf $'models:\n  stages: {validate: opus, deploy: haiku, refine: fable}'
[ "$(sm)" = "fable||opus|haiku|" ] && pass "AC-2 every stage can be set; develop stays unset" || fail "AC-2 three stages set: stage-models printed '$(sm)', want 'fable||opus|haiku|'"
# the frontmatter model of each plugin agent is the default PLUGIN_AGENTS says (it feeds validation and the "Default (...)" label)
got="$(cd "$FACTORY_DIR" && "$FACTORY_PYTHON" -I -c '
import re, sys, pathlib
sys.path.insert(0, ".")
import shipfloor_config as c
want = {}
for f in sorted(pathlib.Path("../agents").glob("*.md")):
    t = f.read_text(encoding="utf-8")
    want[re.search(r"^name:\s*(\S+)", t, re.M).group(1)] = re.search(r"^model:\s*(\S+)", t, re.M).group(1)
have = getattr(c, "PLUGIN_AGENTS", None)
print("same" if have == want else "PLUGIN_AGENTS=%r, agents/*.md say %r" % (have, want))
' 2>&1)"
[ "$got" = same ] && pass "AC-2 PLUGIN_AGENTS matches the model: line of every agents/*.md" || fail "AC-2 PLUGIN_AGENTS does not match agents/*.md: $got"
got="$(cd "$FACTORY_DIR" && "$FACTORY_PYTHON" -I -c '
import sys; sys.path.insert(0, ".")
import shipfloor_config as c
print(getattr(c, "MODELS", None), getattr(c, "STAGE_MODELS", None))' 2>&1)"
assert_contains "$got" "('opus', 'sonnet', 'haiku', 'fable') {'refine': None, 'develop': None, 'validate': 'sonnet', 'deploy': 'sonnet'}"

# AC-3: describe tells the stage skills which model to pass as the Agent tool's model
AC="AC-3"
conf $'models:\n  agents: {engineer: haiku}'
d="$(describe)"
assert_contains "$d" "agent models: engineer=haiku"
case "$d" in *"language:"*"agent models:"*"stack:"*) pass "AC-3 the line sits after language:" ;; *) fail "AC-3 the agent models line is not between language: and stack: in: $d" ;; esac
conf $'models:\n  agents: {engineer: haiku, qa-engineer: opus}'
d="$(describe)"
assert_contains "$d" "agent models: "
assert_contains "$d" "engineer=haiku"
assert_contains "$d" "qa-engineer=opus"
conf $'models:\n  stages: {develop: sonnet}'
no_line "$(describe)" "AC-3 only stages set"
rm -f "$cfgf"
no_line "$(describe)" "AC-3 no config.yml"
for s in develop refine validate deploy; do
  body="$(cat "$FACTORY_DIR/../skills/$s/SKILL.md")"
  case "$body" in *"agent models:"*) pass "AC-3 the $s skill names the agent models: line" ;; *) fail "AC-3 the $s skill never mentions the describe line 'agent models:'" ;; esac
  case "$body" in *"agent models:"*"Agent tool"*"model"*) pass "AC-3 the $s skill hands the model to the Agent tool" ;; *) fail "AC-3 the $s skill does not tell to pass the model to the Agent tool" ;; esac
done

# AC-4: an agent a layer names (layers[].agent) is accepted and printed
AC="AC-4"
conf $'models:\n  agents: {reviewer: haiku}'
assert_contains "$(describe "$PROJ")" "agent models: reviewer=haiku"
no_line "$(describe)" "AC-4 the fixture's layers name no reviewer, so its entry is not this project's"
assert_exit 0 m models-check reviewer
assert_exit 1 m models-check
out="$(m models-check 2>&1)"; assert_contains "$out" 'models.agents.reviewer: not a stage or an agent here'
assert_exit 0 m validate

# AC-5: an unknown model, stage or agent is reported with key and value, never an invalid config.yml
AC="AC-5"
conf $'models:\n  agents: {engineer: gpt}'
out="$(m models-check 2>&1)"; rc=$?
assert_contains "$out" 'models.agents.engineer: "gpt" is not a model the factory knows (opus, sonnet, haiku, fable)'
[ "$rc" = 1 ] && pass "AC-5 models-check exits 1 on an unknown model" || fail "AC-5 models-check exited $rc on an unknown model"
assert_exit 0 m validate
conf $'models:\n  stages: {develop: gpt, validate: gpt}'
out="$(m models-check 2>&1)"
assert_contains "$out" 'models.stages.develop: "gpt" is not a model the factory knows (opus, sonnet, haiku, fable)'
assert_contains "$out" 'models.stages.validate: "gpt"'
assert_exit 0 m validate
[ "$(sm)" = "||sonnet|sonnet|" ] && pass "AC-5 a stage with an unknown model runs on today's model" || fail "AC-5 stage-models printed '$(sm)' for an unknown model, want '||sonnet|sonnet|'"
conf $'models:\n  stages: {develop: opus, deploy: gpt}'
[ "$(sm)" = "|opus|sonnet|sonnet|" ] && pass "AC-5 the valid stage keeps its model, the bad one falls back" || fail "AC-5 stage-models printed '$(sm)', want '|opus|sonnet|sonnet|'"
conf $'models:\n  stages: {review: opus}'
out="$(m models-check 2>&1)"; assert_contains "$out" 'models.stages.review: not a stage or an agent here'
assert_exit 0 m validate
[ "$(sm)" = "||sonnet|sonnet|" ] && pass "AC-5 an unknown stage is ignored" || fail "AC-5 stage-models printed '$(sm)' with an unknown stage, want '||sonnet|sonnet|'"
conf $'models:\n  agents: {nobody: opus}'
out="$(m models-check 2>&1)"; assert_contains "$out" 'models.agents.nobody: not a stage or an agent here'
assert_exit 0 m validate
conf 'models: 3'
assert_exit 1 m models-check
assert_exit 0 m validate
[ "$(sm)" = "||sonnet|sonnet|" ] && pass "AC-5 models that is not a mapping: today's models" || fail "AC-5 stage-models printed '$(sm)' for models: 3, want '||sonnet|sonnet|'"
conf $'models:\n  stages: 3'
assert_exit 1 m models-check
assert_exit 0 m validate
conf $'models:\n  stages: {develop: haiku}\n  agents: {engineer: opus, qa-engineer: sonnet}'
assert_exit 0 m models-check
[ -z "$(m models-check 2>&1)" ] && pass "AC-5 a valid models map is silent" || fail "AC-5 models-check printed '$(m models-check 2>&1)' for a valid map"
# an invalid entry never stops the describe line for the valid ones
conf $'models:\n  agents: {engineer: gpt, qa-engineer: opus}'
d="$(describe)"; assert_contains "$d" "qa-engineer=opus"
case "$d" in *"engineer=gpt"*) fail "AC-5 describe printed the unknown model: $d" ;; *) pass "AC-5 describe leaves out the unknown model" ;; esac
conf $'models:\n  agents: {engineer: gpt}'
no_line "$(describe)" "AC-5 only an unknown model set"

# AC-5: shipfloor doctor warns (WARN, not FAIL) and says ok when the map is clean
SH="$SHIPFLOOR_HOME"; mkdir -p "$SH/projects/shop"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$SH/registry.tsv"; cp "$PROJ" "$SH/projects/shop/factory.yml"
fake="$(mktemp -d)"; mkdir -p "$fake/bin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/bin/gh"; chmod +x "$fake/bin/gh"
doctor() { PATH="$fake/bin:$PATH" HOME="$fake" bash "$M" doctor 2>&1 | grep -E '^(ok  |WARN|FAIL) +(models|project)' || echo "(doctor printed no line about models)"; }
rm -f "$cfgf"
assert_contains "$(doctor)" "ok   project shop"
assert_contains "$(doctor)" "ok   models"
conf $'models:\n  agents: {reviewer: haiku}'
out="$(doctor)"; assert_contains "$out" "ok   models"
case "$out" in *"WARN models:"*) fail "AC-5 doctor warned about a project agent a layer names: $out" ;; *) pass "AC-5 doctor accepts the project's own agent" ;; esac
conf $'models:\n  agents: {engineer: gpt}'
assert_contains "$(doctor)" 'WARN models: models.agents.engineer: "gpt" is not a model the factory knows (opus, sonnet, haiku, fable)'
conf $'models:\n  stages: {review: opus}'
assert_contains "$(doctor)" 'WARN models: models.stages.review: not a stage or an agent here'
conf $'models:\n  agents: {nobody: opus}'
assert_contains "$(doctor)" 'WARN models: models.agents.nobody: not a stage or an agent here'
conf $'models:\n  stages: {develop: gpt}'
out="$(doctor)"
case "$out" in *"FAIL models"*) fail "AC-5 doctor failed on a bad model instead of warning: $out" ;; *) pass "AC-5 a bad model is a WARN, not a FAIL" ;; esac
finish
