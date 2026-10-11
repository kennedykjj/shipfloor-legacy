#!/usr/bin/env bash
# The machine pool caps runs on this machine; each stage has its own slots, shared by every project.
# Validation is the validate stage's queue, no longer a develop work column.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export AGHANIM_HOME="$(mktemp -d)"
  export FACTORY_HOME="$AGHANIM_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" Q_REF= Q_DEV= Q_VAL= Q_PROD= O_COD=
  unset AGHANIM_MAX_PARALLEL
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  cat > "$tmp/board" <<'EOB'
#!/usr/bin/env bash
case "$1 $2" in
  "eligible Ready for Refinement") for n in ${Q_REF:-}; do echo "$n"; done ;;
  "eligible Ready for Dev") for n in ${Q_DEV:-}; do echo "$n"; done ;;
  "eligible Validation") for n in ${Q_VAL:-}; do echo "$n"; done ;;
  "eligible Ready for Prod") for n in ${Q_PROD:-}; do echo "$n"; done ;;
  "eligible Coding") for n in ${O_COD:-}; do echo "$n"; done ;;
  "eligible Staged") for n in ${Q_STG:-}; do echo "$n"; done ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  printf '#!/usr/bin/env bash\necho "$(cat)" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
  printf '#!/usr/bin/env bash
echo "refresh $*" >> "%s/refreshed"
' "$tmp" > "$tmp/deploy"
  chmod +x "$tmp/board" "$tmp/claude" "$tmp/deploy"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude" FACTORY_DEPLOY="$tmp/deploy"
  : > "$tmp/launched"; : > "$tmp/refreshed"; Q_STG=
}
launched() { sort "$tmp/launched" | tr '\n' ' '; }
live_lock() { mkdir -p "$AGHANIM_HOME/projects/$1/locks/$2.lock"; echo "$$ $(date +%s) 1" > "$AGHANIM_HOME/projects/$1/locks/$2.lock/info"; }
machine() { printf '%s\n' "$1" > "$AGHANIM_HOME/config.yml"; }

# validate takes its cards from Validation
setup; Q_VAL="36" run_dispatch; assert_contains "$(launched)" "/aghanim:validate 36"
# a card in Validation is not a develop orphan any more
case "$(launched)" in *"develop 36"*) fail "develop resumed a Validation card" ;; *) pass "Validation is validate's queue" ;; esac

# a stage's slots count live runs of that stage in every project
setup; machine $'pool: 6\nstages: {develop: 1}'; live_lock other develop-9
Q_DEV="26" Q_REF="25" run_dispatch; out="$(launched)"
case "$out" in *develop*) fail "develop past its stage slots: $out" ;; *) pass "stage slots shared across projects" ;; esac
assert_contains "$out" "/aghanim:refine 25"

# the pool caps every stage together
setup; machine $'pool: 2\nstages: {refine: 2, develop: 2, validate: 2, deploy: 1}'; live_lock other refine-3
Q_REF="25" Q_DEV="26" Q_VAL="27" run_dispatch; out="$(launched)"
[ "$(printf '%s' "$out" | grep -o '/aghanim:' | wc -l)" -eq 1 ] && pass "pool of 2 with one live run → one launch" || fail "pool exceeded: $out"

# a stage with 0 slots never runs
setup; machine $'pool: 4\nstages: {deploy: 0}'; Q_PROD="47" run_dispatch
[ -z "$(launched)" ] && pass "stage with 0 slots" || fail "deployed with 0 slots: $(launched)"

# a project sets no cap of its own: the stage's machine slots decide
setup; machine $'pool: 6
stages: {develop: 3}'; Q_DEV="26 27 28" run_dispatch; out="$(launched)"
[ "$(printf '%s' "$out" | grep -o '/aghanim:develop' | wc -l)" -eq 3 ] && pass "no project cap by default" || fail "project default capped the stage: $out"
# deploy keeps one at a time by default (merges into main are serial), whatever the machine allows
setup; machine $'pool: 6
stages: {deploy: 3}'; Q_PROD="47 48" run_dispatch; out="$(cat "$tmp/refreshed")"  # the deploy is a script: the fake logs each call
[ "$(printf '%s' "$out" | grep -c .)" -eq 1 ] && pass "deploy stays serial by default" || fail "parallel deploys by default: $out"

# a card with a live run of any pipeline gets no second run (they would share its worktree)
setup; mkdir -p "$FACTORY_HOME/locks/develop-36.lock"; echo "$$ $(date +%s) 36" > "$FACTORY_HOME/locks/develop-36.lock/info"
Q_VAL="36" run_dispatch; [ -z "$(launched)" ] && pass "busy card skipped" || fail "second run on a busy card: $(launched)"

# staged cards are refreshed only when the project opts in
setup; Q_STG="35" run_dispatch; [ -z "$(cat "$tmp/refreshed")" ] && pass "no refresh by default" || fail "refreshed without opting in"

# staged cards are kept up to date by deploy.sh --refresh, outside the agent pool
setup; cfg="$(mktemp)"; sed '/^deploy:/d' "$FACTORY_CONFIG" > "$cfg"; echo 'deploy: {refresh_staged: true}' >> "$cfg"; export FACTORY_CONFIG="$cfg"; machine $'pool: 1
stages: {refine: 1, develop: 1, validate: 1, deploy: 1}'; live_lock other refine-3
Q_STG="35 36" run_dispatch
assert_contains "$(cat "$tmp/refreshed")" "refresh 35 --refresh"
assert_contains "$(cat "$tmp/refreshed")" "refresh 36 --refresh"
[ -z "$(cat "$tmp/launched")" ] && pass "refreshes use no agent slot" || fail "launched agents: $(cat "$tmp/launched")"
setup; export FACTORY_CONFIG="$cfg"; mkdir -p "$FACTORY_HOME/locks/validate-35.lock"; echo "$$ $(date +%s) 35" > "$FACTORY_HOME/locks/validate-35.lock/info"
Q_STG="35" run_dispatch; [ -z "$(cat "$tmp/refreshed")" ] && pass "busy card not refreshed" || fail "refreshed a busy card"

# an invalid machine config launches nothing
setup; machine 'pool: 0'; Q_REF="25" run_dispatch; code=$?
[ -z "$(launched)" ] && [ "$code" -ne 0 ] && pass "invalid machine config → nothing, non-zero" || fail "launched with an invalid machine config (exit $code)"
finish
