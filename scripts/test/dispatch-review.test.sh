#!/usr/bin/env bash
# Regression tests for review findings on dispatch.sh.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
setup() {
  export FACTORY_HOME="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)"
  tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control"
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "eligible Ready for Refinement") echo 25 ;; *) echo ;; esac\n' > "$tmp/board"
  printf '#!/usr/bin/env bash\necho "$PWD | $(cat) $*" >> "%s/launched"\nsleep "${CLAUDE_SLEEP:-0}"\n' "$tmp" > "$tmp/claude"
  chmod +x "$tmp/board" "$tmp/claude"
  export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
}
launched() { sleep 1; cat "$tmp/launched"; }

# I9: pipelines can write in the issue worktrees; I3/M7: they run from the control checkout
setup; bash "$D"; out="$(launched)"
assert_contains "$out" "--add-dir $FACTORY_WT_ROOT"
assert_contains "$out" "$FACTORY_HOME/control |"

# I7: an old lock whose process is alive is not reclaimed
setup; sleep 30 & live=$!
mkdir -p "$FACTORY_HOME/locks/refine-25.lock"; echo "$live $(( $(date +%s) - 20000 )) 26" > "$FACTORY_HOME/locks/refine-25.lock/info"
bash "$D"; [ -z "$(launched)" ] && pass "old lock with live pid respected" || fail "reclaimed a live lock"
kill "$live" 2>/dev/null

# I7: a fresh lock without info is not reclaimed
setup; mkdir -p "$FACTORY_HOME/locks/refine-25.lock"
bash "$D"; [ -z "$(launched)" ] && pass "fresh lock without info respected" || fail "reclaimed a fresh lock"

# I7: a run removes only its own lock
setup; export CLAUDE_SLEEP=2; bash "$D"; sleep 1
echo "99999 $(date +%s) 30" > "$FACTORY_HOME/locks/refine-25.lock/info"   # another run took over the lock
sleep 3
[ -d "$FACTORY_HOME/locks/refine-25.lock" ] && pass "kept the other run's lock" || fail "deleted another run's lock"
unset CLAUDE_SLEEP

# I3/M7: control checkout tracks origin/main
setup; export FACTORY_CONTROL_REFRESH=1
remote="$(mktemp -d)"; git init -q --bare "$remote"
r="$(new_repo)"; mkdir -p "$r/scripts/factory"; echo v1 > "$r/scripts/factory/marker"
git -C "$r" add -A; git -C "$r" commit -qm m; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
rm -rf "$FACTORY_HOME/control"; export FACTORY_REPO="$r"
bash "$D"; assert_contains "$(cat "$FACTORY_HOME/control/scripts/factory/marker" 2>&1)" "v1"
echo v2 > "$r/scripts/factory/marker"; git -C "$r" commit -qam v2; git -C "$r" push -q origin main
echo tampered > "$FACTORY_HOME/control/scripts/factory/marker"
bash "$D"; assert_contains "$(cat "$FACTORY_HOME/control/scripts/factory/marker")" "v2"
# C3: only the deploy pipeline may merge
setup; printf '#!/usr/bin/env bash
case "$1 $2" in "eligible Ready for Refinement") echo 25 ;; "eligible Ready for Prod") echo 47 ;; *) echo ;; esac
' > "$tmp/board"
bash "$D"; out="$(launched)"
assert_contains "$(printf '%s
' "$out" | grep '/mylos:deploy 47')" '--allowedTools Bash(gh pr merge:*)'
case "$(printf '%s
' "$out" | grep '/mylos:refine 25')" in *"gh pr merge"*) fail "refine may merge" ;; *) pass "refine may not merge" ;; esac
finish
