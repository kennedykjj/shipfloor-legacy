#!/usr/bin/env bash
# The aghanim CLI installs the scripts and manages the project registry.
source "$(dirname "$0")/lib.sh"
M="$FACTORY_DIR/aghanim"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export AGHANIM_HOME="$(mktemp -d)"

with_config() {  # with_config <yaml>: a repo whose origin/main carries that config
  local remote r; remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.aghanim"; printf '%s\n' "$1" > "$r/.aghanim/factory.yml"
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  echo "$r"
}

# install copies the scripts and templates to a fixed place, without the tests
assert_exit 0 bash "$M" install
for f in gate.sh board.sh dispatch.sh aghanim-dispatch.sh aghanim-config.sh aghanim_config.py lib/project.sh aghanim templates/spec-template.md; do
  [ -f "$AGHANIM_HOME/factory/$f" ] && pass "installed $f" || fail "missing $f"
done
[ ! -e "$AGHANIM_HOME/factory/test" ] && pass "tests not installed" || fail "installed the tests"

r="$(with_config "$(cat "$FACTORY_DIR/test/fixture/factory.yml")")"
assert_exit 0 bash "$M" add "$r"
assert_contains "$(cat "$AGHANIM_HOME/registry.tsv")" "shop	$(git -C "$r" rev-parse --show-toplevel)	$AGHANIM_HOME/projects/shop/wt	main"
[ -f "$AGHANIM_HOME/projects/shop/control/.aghanim/factory.yml" ] && pass "control checkout" || fail "no control checkout"
[ -f "$AGHANIM_HOME/projects/shop/factory.yml" ] && pass "config snapshot" || fail "no config snapshot"
assert_exit 0 bash "$M" add "$r"
[ "$(grep -c '^shop	' "$AGHANIM_HOME/registry.tsv")" = 1 ] && pass "add is idempotent" || fail "duplicated the project"
wt="$(mktemp -d)"; assert_exit 0 bash "$M" add "$r" --worktrees "$wt"
assert_contains "$(cat "$AGHANIM_HOME/registry.tsv")" "$wt"

# add again without --worktrees keeps the registered worktrees and reads the config from the new origin/main
sed -i 's/^\(  name: shop\)$/\1 # v2/' "$r/.aghanim/factory.yml"
git -C "$r" commit -qam v2; git -C "$r" push -q origin main
assert_exit 0 bash "$M" add "$r"
assert_contains "$(cat "$AGHANIM_HOME/registry.tsv")" "shop	$(git -C "$r" rev-parse --show-toplevel)	$wt	main"
assert_contains "$(cat "$AGHANIM_HOME/projects/shop/factory.yml")" "# v2"

# another repo cannot take a registered name
other="$(with_config "$(cat "$FACTORY_DIR/test/fixture/factory.yml")")"
assert_exit 1 bash "$M" add "$other"

bad="$(with_config 'project: {name: bad}')"
assert_exit 1 bash "$M" add "$bad"
case "$(cat "$AGHANIM_HOME/registry.tsv")" in *bad*) fail "registered an invalid config" ;; *) pass "invalid config not registered" ;; esac
noconf="$(new_repo)"; assert_exit 1 bash "$M" add "$noconf"

assert_contains "$(bash "$M" list)" "shop"
assert_exit 0 bash "$M" pause shop; [ -e "$AGHANIM_HOME/projects/shop/PAUSE" ] && pass "pause one" || fail "no project PAUSE"
assert_contains "$(bash "$M" list)" "paused"
assert_exit 0 bash "$M" resume shop; [ ! -e "$AGHANIM_HOME/projects/shop/PAUSE" ] && pass "resume one" || fail "PAUSE left"
assert_exit 0 bash "$M" pause; [ -e "$AGHANIM_HOME/PAUSE" ] && pass "pause all" || fail "no global PAUSE"
assert_exit 0 bash "$M" resume; [ ! -e "$AGHANIM_HOME/PAUSE" ] && pass "resume all" || fail "global PAUSE left"
assert_exit 1 bash "$M" pause nope

assert_exit 0 bash "$M" remove shop
case "$(cat "$AGHANIM_HOME/registry.tsv")" in *shop*) fail "still registered" ;; *) pass "removed" ;; esac
[ ! -e "$AGHANIM_HOME/projects/shop/control" ] && pass "control checkout removed" || fail "control left behind"
assert_exit 1 bash "$M" remove shop
assert_exit 2 bash "$M" nonsense

# the machine pool
assert_contains "$(bash "$M" pool)" "pool: 4"
assert_exit 0 bash "$M" pool set 6
assert_exit 0 bash "$M" pool stage validate 3
out="$(bash "$M" pool)"; assert_contains "$out" "pool: 6"; assert_contains "$out" "validate: 3"
mkdir -p "$AGHANIM_HOME/projects/a/locks/validate-7.lock"; echo "$$ $(date +%s) 7" > "$AGHANIM_HOME/projects/a/locks/validate-7.lock/info"
assert_contains "$(bash "$M" pool)" "validate: 3 (1 running)"
assert_exit 1 bash "$M" pool stage validate 9
assert_exit 1 bash "$M" pool stage review 1
assert_contains "$(bash "$M" pool)" "validate: 3"

# doctor tells a machine that still has the old home to migrate it
fake="$(mktemp -d)"; mkdir -p "$fake/.mylos"
out="$(HOME="$fake" AGHANIM_HOME="$fake/.aghanim" bash "$M" doctor 2>&1)"
assert_contains "$out" "aghanim migrate-home"

# clean removes tmp/<n>/ of cards that are Done or off the board, and keeps the active ones
assert_exit 0 bash "$M" add "$r"
H2="$AGHANIM_HOME/projects/shop"; mkdir -p "$H2/tmp/5/x" "$H2/tmp/6/x" "$H2/tmp/8/x"
printf '5	Done	I5
6	Coding	I6
' > "$H2/board.tsv"
assert_contains "$(bash "$M" doctor 2>&1)" "aghanim clean shop"
# doctor names a project the dispatcher skips, and a control checkout behind origin/main
printf '2026-10-09T20:06:50-03:00\tcannot bring the control checkout to origin/main: index.lock exists\n' > "$H2/SKIPPED"
out="$(bash "$M" doctor 2>&1)"; assert_contains "$out" "shop: the dispatcher skips it since 2026-10-09T20:06:50"
assert_contains "$out" "index.lock exists"
rm "$H2/SKIPPED"; git -C "$r" commit -q --allow-empty -m ahead; git -C "$r" push -q origin HEAD:main
assert_contains "$(bash "$M" doctor 2>&1)" "shop: control checkout is behind origin/main"
assert_exit 0 bash "$M" clean shop
[ ! -e "$H2/tmp/5" ] && [ ! -e "$H2/tmp/8" ] && [ -d "$H2/tmp/6" ] && pass "clean keeps the active card" || fail "clean removed the wrong tmp dirs: $(ls "$H2/tmp")"
# accept: the owner records the acceptance files of a card as reviewed, with a reason, and the gate takes them
W="$(mktemp -d)/9"; git -C "$r" worktree add -q -b feat/9-x "$W" main; mkdir -p "$W/api/src/test"
echo qa > "$W/api/src/test/NineTest.kt"; git -C "$W" add -A; git -C "$W" commit -qm "test(x): acceptance tests for #9"
qa9="$(git -C "$W" rev-parse HEAD)"
echo resolved > "$W/api/src/test/NineTest.kt"; git -C "$W" commit -qam "merge resolved by hand"
sed -i "s#^shop\t\([^\t]*\)\t[^\t]*#shop\t\1\t$(dirname "$W")#" "$AGHANIM_HOME/registry.tsv"
assert_exit 2 bash "$M" accept shop 9
assert_exit 1 bash "$FACTORY_DIR/gate.sh" -C "$W" acceptance-intact "$qa9"
out="$(bash "$M" accept shop 9 main reworded the setup 2>&1)"; assert_contains "$out" "api/src/test/NineTest.kt"
assert_contains "$(cat "$H2/accepted.tsv")" "main reworded the setup"
assert_exit 0 bash "$FACTORY_DIR/gate.sh" -C "$W" acceptance-intact "$qa9"
assert_contains "$(bash "$M" accept shop 9 again 2>&1)" "nothing to accept"
# pool shows the stack slots
out="$(bash "$M" pool)"; assert_contains "$out" "stacks: 3"; assert_contains "$out" "slot 0: free"
finish
