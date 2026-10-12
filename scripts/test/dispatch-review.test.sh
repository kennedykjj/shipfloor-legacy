#!/usr/bin/env bash
# Regression tests for review findings on dispatch.sh.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export FACTORY_HOME="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Refinement") echo 25 ;; *) echo ;; esac\n' > "$tmp/board"
  # CLAUDE_HOLD names a file: the fake agent waits until it exists, at most TEST_WAIT_SECS seconds (a failed case leaves no process behind)
  printf '#!/usr/bin/env bash\necho "$PWD | $(cat) $*" >> "%s/launched"\nif [ -n "${CLAUDE_HOLD:-}" ]; then t0=$SECONDS; while [ ! -e "$CLAUDE_HOLD" ] && [ $((SECONDS - t0)) -lt "${TEST_WAIT_SECS:-60}" ]; do sleep 0.1; done; fi\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"
  export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
}
launched() { cat "$tmp/launched"; }

# I9: pipelines can write in the issue worktrees; I3/M7: they run from the control checkout
setup; run_dispatch; out="$(launched)"
assert_contains "$out" "--add-dir $FACTORY_WT_ROOT"
assert_contains "$out" "$FACTORY_HOME/control |"

# I7: an old lock whose process is alive is not reclaimed
setup; sleep 60 & live=$!
mkdir -p "$FACTORY_HOME/locks/refine-25.lock"; echo "$live $(( $(date +%s) - 20000 )) 26" > "$FACTORY_HOME/locks/refine-25.lock/info"
run_dispatch; [ -z "$(launched)" ] && pass "old lock with live pid respected" || fail "reclaimed a live lock"
kill "$live" 2>/dev/null

# I7: a fresh lock without info is not reclaimed
setup; mkdir -p "$FACTORY_HOME/locks/refine-25.lock"
run_dispatch; [ -z "$(launched)" ] && pass "fresh lock without info respected" || fail "reclaimed a fresh lock"

# I7: a run removes only its own lock
gone() { ! kill -0 "$1" 2>/dev/null; }   # gone <pid>: the process no longer exists
no_end() { ! grep -qs '== end' "$FACTORY_HOME"/logs/*-25-refine.log; }   # the run has not ended yet
if ! type wait_for >/dev/null 2>&1; then
  fail "AC-1 AC-2 AC-3: expected lib.sh to offer a bounded wait (wait_for <what> <command...>) so the case can wait for the run, and it offers none"
else
  # AC-1, AC-2: a live run whose info now names another owner keeps that lock when it ends
  setup; export CLAUDE_HOLD="$tmp/release"; bash "$D"
  wait_for "the run to start (launched non-empty)" test -s "$tmp/launched"
  read -r run_pid _ < "$FACTORY_HOME/locks/refine-25.lock/info"
  no_end && pass "AC-2 run is live before the takeover" || fail "AC-2 run already ended before the takeover"
  echo "99999 $(date +%s) 30" > "$FACTORY_HOME/locks/refine-25.lock/info"   # another run took over the lock
  no_end && pass "AC-2 run is still live after the takeover" || fail "AC-2 run ended during the takeover"
  touch "$tmp/release"
  wait_for "the run (pid $run_pid) to exit" gone "$run_pid"
  [ -d "$FACTORY_HOME/locks/refine-25.lock" ] && pass "AC-1 kept the other run's lock" || fail "AC-1 deleted another run's lock"
  read -r owner _ < "$FACTORY_HOME/locks/refine-25.lock/info" 2>/dev/null
  [ "${owner:-}" = "99999" ] && pass "AC-1 info still names the other owner" || fail "AC-1 info names '${owner:-}', want 99999"
  unset CLAUDE_HOLD

  # AC-3: the same run with nobody rewriting info removes its own lock
  setup; export CLAUDE_HOLD="$tmp/release"; bash "$D"
  wait_for "the run to start (launched non-empty)" test -s "$tmp/launched"
  read -r run_pid _ < "$FACTORY_HOME/locks/refine-25.lock/info"
  touch "$tmp/release"
  wait_for "the run (pid $run_pid) to exit" gone "$run_pid"
  wait_for "the run's own lock to be removed" test ! -d "$FACTORY_HOME/locks/refine-25.lock" \
    && pass "AC-3 a run removes its own lock" || fail "AC-3 the run left its own lock behind"
  unset CLAUDE_HOLD
fi

# I3/M7: control checkout tracks origin/main
setup; export FACTORY_CONTROL_REFRESH=1
remote="$(mktemp -d)"; git init -q --bare "$remote"
r="$(new_repo)"; mkdir -p "$r/scripts/factory"; echo v1 > "$r/scripts/factory/marker"
git -C "$r" add -A; git -C "$r" commit -qm m; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
rm -rf "$FACTORY_HOME/control"; export FACTORY_REPO="$r"
run_dispatch; assert_contains "$(cat "$FACTORY_HOME/control/scripts/factory/marker" 2>&1)" "v1"
echo v2 > "$r/scripts/factory/marker"; git -C "$r" commit -qam v2; git -C "$r" push -q origin main
echo tampered > "$FACTORY_HOME/control/scripts/factory/marker"
run_dispatch; assert_contains "$(cat "$FACTORY_HOME/control/scripts/factory/marker")" "v2"
# the deploy is a script; an agent runs only to resolve conflicts it hands over (exit 3), then --continue
deploy_case() {  # deploy_case <first exit>: fake deploy.sh exits <first exit>, then 0 on --continue
  setup; printf '#!/usr/bin/env bash
case "$1 $2" in "eligible Ready for Prod") echo 47 ;; *) echo ;; esac
' > "$tmp/board"
  printf '#!/usr/bin/env bash
echo "deploy.sh $*" >> "%s/launched"
[ "${2:-}" = --continue ] && exit 0
exit %s
' "$tmp" "$1" > "$tmp/deploy"
  chmod +x "$tmp/deploy"; export FACTORY_DEPLOY="$tmp/deploy"; run_dispatch
}
deploy_case 0; out="$(cat "$tmp/launched")"
assert_contains "$out" "deploy.sh 47"
case "$out" in *"/sf:deploy"*) fail "an agent ran a clean deploy" ;; *) pass "clean deploy needs no agent" ;; esac
deploy_case 3; out="$(cat "$tmp/launched")"
assert_contains "$out" "/sf:deploy 47"
assert_contains "$out" "deploy.sh 47 --continue"
unset FACTORY_DEPLOY
finish
