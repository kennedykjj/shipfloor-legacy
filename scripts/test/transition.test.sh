#!/usr/bin/env bash
# The factory reads .shipfloor/factory.yml only, keeps that dir off-limits to agents,
# and does not read the dir of the old name.
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

# install drops files the plugin no longer ships
export SHIPFLOOR_HOME="$(mktemp -d)"; mkdir -p "$SHIPFLOOR_HOME/factory"
echo stale > "$SHIPFLOOR_HOME/factory/retired-script.sh"
assert_exit 0 bash "$(plugin_copy)/scripts/shipfloor" install
[ ! -e "$SHIPFLOOR_HOME/factory/retired-script.sh" ] && pass "stale installed file removed" || fail "stale installed file kept"
[ -f "$SHIPFLOOR_HOME/factory/gate.sh" ] && [ -f "$SHIPFLOOR_HOME/factory/.source" ] && pass "install still complete" || fail "install incomplete"
finish
