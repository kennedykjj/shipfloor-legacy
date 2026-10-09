#!/usr/bin/env bash
# The mylos CLI installs the scripts and manages the project registry.
source "$(dirname "$0")/lib.sh"
M="$FACTORY_DIR/mylos"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export MYLOS_HOME="$(mktemp -d)"

with_config() {  # with_config <yaml>: a repo whose origin/main carries that config
  local remote r; remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.mylos"; printf '%s\n' "$1" > "$r/.mylos/factory.yml"
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  echo "$r"
}

# install copies the scripts and templates to a fixed place, without the tests
assert_exit 0 bash "$M" install
for f in gate.sh board.sh dispatch.sh mylos-dispatch.sh mylos-config.sh mylos_config.py lib/project.sh mylos templates/spec-template.md; do
  [ -f "$MYLOS_HOME/factory/$f" ] && pass "installed $f" || fail "missing $f"
done
[ ! -e "$MYLOS_HOME/factory/test" ] && pass "tests not installed" || fail "installed the tests"

r="$(with_config "$(cat "$FACTORY_DIR/test/fixture/factory.yml")")"
assert_exit 0 bash "$M" add "$r"
assert_contains "$(cat "$MYLOS_HOME/registry.tsv")" "shop	$(git -C "$r" rev-parse --show-toplevel)	$MYLOS_HOME/projects/shop/wt	main"
[ -f "$MYLOS_HOME/projects/shop/control/.mylos/factory.yml" ] && pass "control checkout" || fail "no control checkout"
assert_exit 0 bash "$M" add "$r"
[ "$(grep -c '^shop	' "$MYLOS_HOME/registry.tsv")" = 1 ] && pass "add is idempotent" || fail "duplicated the project"
wt="$(mktemp -d)"; assert_exit 0 bash "$M" add "$r" --worktrees "$wt"
assert_contains "$(cat "$MYLOS_HOME/registry.tsv")" "$wt"

# another repo cannot take a registered name
other="$(with_config "$(cat "$FACTORY_DIR/test/fixture/factory.yml")")"
assert_exit 1 bash "$M" add "$other"

bad="$(with_config 'project: {name: bad}')"
assert_exit 1 bash "$M" add "$bad"
case "$(cat "$MYLOS_HOME/registry.tsv")" in *bad*) fail "registered an invalid config" ;; *) pass "invalid config not registered" ;; esac
noconf="$(new_repo)"; assert_exit 1 bash "$M" add "$noconf"

assert_contains "$(bash "$M" list)" "shop"
assert_exit 0 bash "$M" pause shop; [ -e "$MYLOS_HOME/projects/shop/PAUSE" ] && pass "pause one" || fail "no project PAUSE"
assert_contains "$(bash "$M" list)" "paused"
assert_exit 0 bash "$M" resume shop; [ ! -e "$MYLOS_HOME/projects/shop/PAUSE" ] && pass "resume one" || fail "PAUSE left"
assert_exit 0 bash "$M" pause; [ -e "$MYLOS_HOME/PAUSE" ] && pass "pause all" || fail "no global PAUSE"
assert_exit 0 bash "$M" resume; [ ! -e "$MYLOS_HOME/PAUSE" ] && pass "resume all" || fail "global PAUSE left"
assert_exit 1 bash "$M" pause nope

assert_exit 0 bash "$M" remove shop
case "$(cat "$MYLOS_HOME/registry.tsv")" in *shop*) fail "still registered" ;; *) pass "removed" ;; esac
[ ! -e "$MYLOS_HOME/projects/shop/control" ] && pass "control checkout removed" || fail "control left behind"
assert_exit 1 bash "$M" remove shop
assert_exit 2 bash "$M" nonsense
finish
