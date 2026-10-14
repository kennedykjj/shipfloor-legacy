#!/usr/bin/env bash
# refresh_control brings the control checkout to origin/<FACTORY_MAIN>, whatever the project calls its main branch.
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"
export SHIPFLOOR_HOME="$(mktemp -d)"
export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
remote="$(mktemp -d)"; git init -q --bare "$remote"
repo="$(new_repo)"; git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q origin main
git -C "$repo" checkout -qb trunk; echo trunk > "$repo/trunk.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm trunk
git -C "$repo" push -q origin trunk; git -C "$remote" symbolic-ref HEAD refs/heads/trunk
trunk_sha="$(git -C "$repo" rev-parse trunk)"; main_sha="$(git -C "$repo" rev-parse main)"
export FACTORY_REPO="$repo" FACTORY_MAIN=trunk
tmp="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$1 ${2:-}" in "eligible Ready for Dev") echo 26 ;; "count "*) echo 0 ;; *) echo ;; esac\n' > "$tmp/board"
printf '#!/usr/bin/env bash\necho "$(cat)" >> "%s/launched"\n' "$tmp" > "$tmp/claude"
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"; : > "$tmp/launched"
unset FACTORY_CONTROL_REFRESH

run_dispatch >/dev/null 2>&1
C="$FACTORY_HOME/control"
[ "$(git -C "$C" rev-parse HEAD 2>/dev/null)" = "$trunk_sha" ] && pass "AC-7 the control checkout is at origin/trunk, not origin/main" || fail "AC-7 control at '$(git -C "$C" rev-parse HEAD 2>/dev/null)', want $trunk_sha (main is $main_sha)"
case "$(cat "$tmp/launched")" in *"/sf:develop 26"*) pass "AC-7 the card starts after the refresh" ;; *) fail "AC-7 nothing launched" ;; esac

# a new commit on trunk: the next refresh follows it
echo more > "$repo/more.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm more; git -C "$repo" push -q origin trunk
trunk_sha="$(git -C "$repo" rev-parse trunk)"; rm -rf "$FACTORY_HOME/locks"
run_dispatch >/dev/null 2>&1
[ "$(git -C "$C" rev-parse HEAD 2>/dev/null)" = "$trunk_sha" ] && pass "AC-7 a later cycle resets to the new origin/trunk" || fail "AC-7 control at '$(git -C "$C" rev-parse HEAD 2>/dev/null)', want $trunk_sha"

# a repository with no main branch at all
git -C "$repo" push -q origin --delete main
rm -rf "$FACTORY_HOME/control" "$FACTORY_HOME/locks"; git -C "$repo" worktree prune; git -C "$repo" update-ref -d refs/remotes/origin/main
: > "$tmp/launched"; run_dispatch >/dev/null 2>&1
case "$(cat "$tmp/launched")" in *"/sf:develop 26"*) pass "AC-7 a project whose main is trunk needs no origin/main" ;; *) fail "AC-7 refresh failed without origin/main" ;; esac
finish
