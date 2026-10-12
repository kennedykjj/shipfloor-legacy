#!/usr/bin/env bash
# The factory reads .shipfloor/factory.yml only, keeps that dir off-limits to agents,
# and migrate-home moves the home of the old name.
source "$(dirname "$0")/lib.sh"
M="$FACTORY_DIR/shipfloor"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export SHIPFLOOR_HOME="$(mktemp -d)"
FIX="$(cat "$FACTORY_DIR/test/fixture/factory.yml")"

repo_with() {  # repo_with <dir>...: a repo whose origin/main has the fixture config in each dir
  local remote r d; remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"
  for d in "$@"; do mkdir -p "$r/$d"; printf '%s\n' "$FIX" > "$r/$d/factory.yml"; done
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  echo "$r"
}

# registered, no warning
r="$(repo_with .shipfloor)"
out="$(bash "$M" add "$r" 2>&1)"; rc=$?
[ $rc = 0 ] && pass "add reads .shipfloor/factory.yml" || fail "add .shipfloor → $rc: $out"
case "$out" in *legacy*) fail "warned on the config dir" ;; *) pass "no warning" ;; esac

# the config dir stays forbidden to agents
re="$(FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" bash "$FACTORY_DIR/shipfloor-config.sh" regex forbidden)"
printf '%s
' .shipfloor/factory.yml | grep -qE -- "$re" && pass "forbidden: .shipfloor/factory.yml" || fail "not forbidden: .shipfloor/factory.yml"
grep -q '\.shipfloor/' "$FACTORY_DIR/../templates/factory-guard.yml" && pass "guard blocks .shipfloor/" || fail "guard misses .shipfloor/"

# an old config dir is not read: no fallback
bash "$M" remove shop >/dev/null 2>&1
assert_exit 1 bash "$M" add "$(repo_with .aghanim)"

# neither dir: refused
bash "$M" remove shop >/dev/null 2>&1
assert_exit 1 bash "$M" add "$(new_repo)"

# migrate-home moves the old home and keeps its worktrees linked
mk_old() {  # mk_old: a legacy home with one project whose control is a worktree of a repo; prints "old repo"
  local base old repo; base="$(mktemp -d)"; old="$base/.aghanim"; mkdir -p "$old/projects/shop/locks"
  repo="$(new_repo)"; git -C "$repo" worktree add -q --detach "$old/projects/shop/control" main
  echo "$old $repo"
}
read -r old repo <<< "$(mk_old)"
export SHIPFLOOR_HOME="$(mktemp -d)/.shipfloor"
assert_exit 0 bash "$M" migrate-home "$old"
[ ! -e "$old" ] && pass "old home gone" || fail "old home still there"
assert_exit 0 git -C "$SHIPFLOOR_HOME/projects/shop/control" status
case "$(git -C "$repo" worktree list --porcelain)" in *prunable*) fail "worktree left prunable" ;; *) pass "worktree relinked" ;; esac

# the registry follows the move, and card worktrees under wt/ stay linked
read -r old repo <<< "$(mk_old)"
git -C "$repo" worktree add -q -b feat/12-x "$old/projects/shop/wt/12" main
printf 'shop	%s	%s	main
' "$repo" "$old/projects/shop/wt" > "$old/registry.tsv"
export SHIPFLOOR_HOME="$(mktemp -d)/.shipfloor"
assert_exit 0 bash "$M" migrate-home "$old"
assert_contains "$(cat "$SHIPFLOOR_HOME/registry.tsv")" "$SHIPFLOOR_HOME/projects/shop/wt"
case "$(cat "$SHIPFLOOR_HOME/registry.tsv")" in *"$old"*) fail "registry still points at the old home" ;; *) pass "registry rewritten" ;; esac
case "$(git -C "$repo" worktree list --porcelain)" in *prunable*) fail "card worktree left prunable" ;; *) pass "card worktree relinked" ;; esac
assert_exit 0 git -C "$SHIPFLOOR_HOME/projects/shop/wt/12" status

# refuses while a run holds a lock
read -r old repo <<< "$(mk_old)"; mkdir "$old/projects/shop/locks/develop-12.lock"
export SHIPFLOOR_HOME="$(mktemp -d)/.shipfloor"
assert_exit 1 bash "$M" migrate-home "$old"
[ -d "$old" ] && [ ! -e "$SHIPFLOOR_HOME" ] && pass "lock: nothing moved" || fail "moved with a live lock"

# refuses to merge into an existing home
read -r old repo <<< "$(mk_old)"
export SHIPFLOOR_HOME="$(mktemp -d)"   # exists already
assert_exit 1 bash "$M" migrate-home "$old"
[ -d "$old/projects/shop/control" ] && pass "existing target: nothing moved" || fail "touched the old home"

# missing old home
assert_exit 1 bash "$M" migrate-home "$(mktemp -d)/nope"

# install drops files the plugin no longer ships (the old scripts after migrate-home)
export SHIPFLOOR_HOME="$(mktemp -d)"; mkdir -p "$SHIPFLOOR_HOME/factory"
echo stale > "$SHIPFLOOR_HOME/factory/aghanim-dispatch.sh"
assert_exit 0 bash "$(plugin_copy)/scripts/shipfloor" install
[ ! -e "$SHIPFLOOR_HOME/factory/aghanim-dispatch.sh" ] && pass "stale installed file removed" || fail "stale installed file kept"
[ -f "$SHIPFLOOR_HOME/factory/gate.sh" ] && [ -f "$SHIPFLOOR_HOME/factory/.source" ] && pass "install still complete" || fail "install incomplete"
finish
