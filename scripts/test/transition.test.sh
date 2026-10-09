#!/usr/bin/env bash
# During the rename the factory reads .aghanim/factory.yml, falls back to the legacy .mylos/ one,
# and keeps both dirs off-limits to agents.
source "$(dirname "$0")/lib.sh"
M="$FACTORY_DIR/aghanim"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export AGHANIM_HOME="$(mktemp -d)"
FIX="$(cat "$FACTORY_DIR/test/fixture/factory.yml")"

repo_with() {  # repo_with <dir>...: a repo whose origin/main has the fixture config in each dir
  local remote r d; remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"
  for d in "$@"; do mkdir -p "$r/$d"; printf '%s\n' "$FIX" > "$r/$d/factory.yml"; done
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  echo "$r"
}

# new dir: registered, no warning
r="$(repo_with .aghanim)"
out="$(bash "$M" add "$r" 2>&1)"; rc=$?
[ $rc = 0 ] && pass "add reads .aghanim/factory.yml" || fail "add .aghanim → $rc: $out"
case "$out" in *legacy*) fail "warned on the new dir" ;; *) pass "no warning on the new dir" ;; esac

# legacy dir only: registered, with a warning
bash "$M" remove shop >/dev/null 2>&1
r="$(repo_with .mylos)"
out="$(bash "$M" add "$r" 2>&1)"; rc=$?
[ $rc = 0 ] && pass "add falls back to .mylos/factory.yml" || fail "add .mylos → $rc: $out"
assert_contains "$out" "legacy .mylos/factory.yml"
[ -f "$AGHANIM_HOME/projects/shop/factory.yml" ] && pass "snapshot from the legacy dir" || fail "no snapshot"

# both dirs: the new one wins, silently
bash "$M" remove shop >/dev/null 2>&1
r="$(repo_with .aghanim .mylos)"
echo "# from-aghanim" >> "$r/.aghanim/factory.yml"; git -C "$r" commit -qam mark; git -C "$r" push -q origin main
out="$(bash "$M" add "$r" 2>&1)"
case "$out" in *legacy*) fail "warned although .aghanim exists" ;; *) pass "both dirs: no warning" ;; esac
grep -q 'from-aghanim' "$AGHANIM_HOME/projects/shop/factory.yml" && pass ".aghanim wins over .mylos" || fail "read the legacy file"

# both dirs stay forbidden to agents
re="$(FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" bash "$FACTORY_DIR/aghanim-config.sh" regex forbidden)"
for p in .aghanim/factory.yml .mylos/factory.yml; do
  printf '%s\n' "$p" | grep -qE -- "$re" && pass "forbidden: $p" || fail "not forbidden: $p"
done
grep -q '\\.aghanim/' "$FACTORY_DIR/../templates/factory-guard.yml" && pass "guard blocks .aghanim/" || fail "guard misses .aghanim/"
grep -q '\\.mylos/' "$FACTORY_DIR/../templates/factory-guard.yml" && pass "guard blocks .mylos/" || fail "guard misses .mylos/"

# neither dir: refused
bash "$M" remove shop >/dev/null 2>&1
assert_exit 1 bash "$M" add "$(new_repo)"
finish
