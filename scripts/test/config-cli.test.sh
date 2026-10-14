#!/usr/bin/env bash
# suite: integration
# shipfloor-config.sh through real processes (the answers are in py/config_project.py and py/config_machine.py):
# exit codes 0 / 1 / 2 and what goes to stdout and stderr, `machine ...` from outside any project (the installer's
# question), lib/project.sh's shipfloor_machine, `step <k>` (the Bash fast path, no Python), and shipfloor doctor's
# models line.
source "$(dirname "$0")/lib.sh"
CFG="$FACTORY_DIR/shipfloor-config.sh"
c() { bash "$CFG" "$@"; }

# the project queries: stdout is the answer, CR-free; 1 is a negative answer, 2 an unusable call
assert_exit 0 c validate
[ "$(c get project.repo)" = acme/shop ] && pass "get prints the value" || fail "get project.repo: $(c get project.repo)"
case "$(c get project.repo | od -c)" in *'\r'*) fail "CR in output" ;; *) pass "no CR in output" ;; esac
[ "$(c layers | tr '\n' ' ')" = "api web e2e " ] && pass "a list, one per line" || fail "layers: $(c layers)"
assert_exit 1 c get project.nothing
assert_exit 2 c layer nope path
bad="$(mktemp)"; printf 'project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\n' > "$bad"
out="$(FACTORY_CONFIG="$bad" bash "$CFG" validate 2>"$bad.err")"; rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -qx "shipfloor-config: $bad: layers must be a non-empty list" "$bad.err" && pass "validate refuses: exit 1, the reason on stderr" || fail "validate: exit $rc, out '$out', err $(cat "$bad.err")"
assert_exit 2 env FACTORY_CONFIG=/nonexistent/factory.yml bash "$CFG" get project.repo
nowhere="$(mktemp -d)"
out="$(cd "$nowhere" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$(mktemp -d)" bash "$CFG" get project.repo 2>&1)"; rc=$?
[ "$rc" = 2 ] && assert_contains "$out" "is not in a registered project" || fail "no project: exit $rc: $out"

# machine ... needs no project: the installer asks for dispatcher.every_min with only SHIPFLOOR_HOME to go by
H="$(mktemp -d)"
ask() { (cd "$nowhere" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$H" bash "$CFG" machine values dispatcher.every_min | tr '\0' ' '); }
[ "$(ask)" = "3 " ] && pass "outside a project, no config.yml: every_min 3" || fail "no config.yml printed: $(ask)"
printf 'dispatcher: {every_min: 10}\n' > "$H/config.yml"
[ "$(ask)" = "10 " ] && pass "outside a project, config.yml every_min 10 prints 10" || fail "every_min 10 printed: $(ask)"
(cd "$nowhere" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$H" bash "$CFG" machine values dispatcher.every_min >/dev/null) && pass "and exits 0" || fail "machine values outside a project: exit $?"
assert_exit 1 env SHIPFLOOR_HOME="$H" bash "$CFG" machine set dispatcher.every_min 5
grep -q 'every_min: 10' "$H/config.yml" && pass "the file is unchanged by the refused set" || fail "config.yml changed: $(cat "$H/config.yml")"
m() { SHIPFLOOR_HOME="$H" bash -c "source '$FACTORY_DIR/lib/project.sh'; shipfloor_machine \"\$@\"" _ "$@"; }
[ "$(m values pool dispatcher.every_min | tr '\0' ' ')" = "4 10 " ] && pass "lib/project.sh's shipfloor_machine answers from config.yml" || fail "shipfloor_machine: $(m values pool | tr '\0' ' ')"
printf 'pool: 0\n' > "$H/config.yml"
assert_exit 1 m validate
assert_exit 2 m values pool
# The installer without -EveryMin: -DryRun writes nothing; it reads the INSTALLED copy in the real home,
# so only the shape of the answer is asserted.
if command -v powershell >/dev/null 2>&1; then
  PS1="$FACTORY_DIR/../installer/install-dispatcher.ps1"
  if command -v cygpath >/dev/null 2>&1; then PS1="$(cygpath -w "$PS1")"; fi
  dry="$(powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1" -DryRun 2>&1)"
  case "$dry" in
    *"ShipfloorDispatcher: every 1 minutes"*|*"ShipfloorDispatcher: every 3 minutes"*|*"ShipfloorDispatcher: every 5 minutes"*|*"ShipfloorDispatcher: every 10 minutes"*)
      pass "installer -DryRun without -EveryMin names a pace" ;;
    *) fail "installer -DryRun printed: $dry" ;;
  esac
fi

# step <k> (#161, PY-08): the skill step a run records for the dashboard, k<TAB><epoch> in <lock>/step. Never fails a run.
unset SHIPFLOOR_RUN_LOCK
lock="$(mktemp -d)"; t0="$(date +%s)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step 3
t1="$(date +%s)"; IFS=$'\t' read -r k ts rest < "$lock/step"
[ "$k" = 3 ] && [ -z "$rest" ] && [ "$ts" -ge "$t0" ] 2>/dev/null && [ "$ts" -le "$t1" ] && [ "$(wc -l < "$lock/step" | tr -d ' ')" = 1 ] \
  && pass "AC-6 step 3 writes one line: k, the epoch of the call" || fail "AC-6 step file: $(od -c "$lock/step" | head -3)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step 12
[ "$(cut -f1 "$lock/step")" = 12 ] && [ "$(grep -c . "$lock/step")" = 1 ] && pass "AC-6 a later step replaces the earlier one" || fail "AC-6 after 12: $(cat "$lock/step")"
before="$(cat "$lock/step")"
for bad in x 3a -1 1.5 "" "1 2"; do assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step "$bad"; done
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step
[ "$(cat "$lock/step")" = "$before" ] && pass "AC-6 a non-numeric or missing k writes nothing" || fail "AC-6 step file changed to: $(cat "$lock/step")"
lock2="$(mktemp -d)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$lock2" bash "$CFG" step abc
[ ! -e "$lock2/step" ] && pass "AC-6 a non-numeric k creates no step file" || fail "AC-6 step file for abc: $(cat "$lock2/step")"
assert_exit 0 env SHIPFLOOR_RUN_LOCK= bash "$CFG" step 5
gone="$(mktemp -d)/no-such-lock"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$gone" bash "$CFG" step 5
[ ! -e "$gone" ] && pass "AC-6 a missing lock folder is not created" || fail "AC-6 created $gone"
cwd="$(mktemp -d)"; ( cd "$cwd" && bash "$CFG" step 5 ); rc=$?
[ "$rc" = 0 ] && [ -z "$(find "$cwd" -mindepth 1 -print -quit)" ] && pass "AC-6 no lock: exit 0, nothing written anywhere" || fail "AC-6 no lock: exit $rc, or a file in $cwd"
file="$(mktemp)"
assert_exit 0 env SHIPFLOOR_RUN_LOCK="$file" bash "$CFG" step 5
[ ! -s "$file" ] && pass "AC-6 a lock that is a file is left alone" || fail "AC-6 wrote into a file lock"
assert_exit 0 env -u FACTORY_CONFIG FACTORY_PYTHON=/nonexistent/python SHIPFLOOR_HOME="$(mktemp -d)" SHIPFLOOR_RUN_LOCK="$lock2" bash "$CFG" step 7
[ "$(cut -f1 "$lock2/step")" = 7 ] && pass "AC-6 step needs no project config and starts no Python" || fail "AC-6 step without a config: $(cat "$lock2/step" 2>/dev/null)"

# shipfloor doctor: a bad models entry is a WARN (never a FAIL) with its key; a clean map, or a project's own agent, is ok
SH="$(mktemp -d)"; mkdir -p "$SH/projects/shop"; printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$SH/registry.tsv"
printf 'project: {name: shop, repo: acme/shop}\nboard: {owner: acme, number: 7}\nlayers:\n  - {name: api, path: api/, agent: reviewer, test: t, ran: ok, tests: [api/t/**]}\n' > "$SH/projects/shop/factory.yml"
fake="$(mktemp -d)"; mkdir -p "$fake/bin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/bin/gh"; chmod +x "$fake/bin/gh"
doctor() { PATH="$fake/bin:$PATH" HOME="$fake" SHIPFLOOR_HOME="$SH" bash "$FACTORY_DIR/shipfloor" doctor 2>&1 | grep -E '^(ok  |WARN|FAIL) +(models|project)' || echo "(doctor printed no line about models)"; }
out="$(doctor)"; assert_contains "$out" "ok   project shop"; assert_contains "$out" "ok   models"
printf 'models:\n  agents: {reviewer: haiku}\n' > "$SH/config.yml"
out="$(doctor)"; case "$out" in *"ok   models"*) case "$out" in *WARN*) fail "doctor warned about the project's own agent: $out" ;; *) pass "doctor accepts the agent a layer names" ;; esac ;; *) fail "doctor: $out" ;; esac
printf 'models:\n  agents: {engineer: gpt}\n' > "$SH/config.yml"
assert_contains "$(doctor)" 'WARN models: models.agents.engineer: "gpt" is not a model the factory knows (opus, sonnet, haiku, fable)'
printf 'models:\n  stages: {review: opus}\n  agents: {nobody: opus}\n' > "$SH/config.yml"
out="$(doctor)"; assert_contains "$out" 'WARN models: models.stages.review: not a stage or an agent here'
assert_contains "$out" 'WARN models: models.agents.nobody: not a stage or an agent here'
case "$out" in *"FAIL models"*) fail "doctor failed on a bad models entry instead of warning: $out" ;; *) pass "a bad models entry is a WARN, not a FAIL" ;; esac
finish
