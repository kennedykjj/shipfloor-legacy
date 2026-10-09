#!/usr/bin/env bash
# Without FACTORY_CONFIG the scripts find the project through ~/.aghanim/registry.tsv and read the
# config from the snapshot of its main branch, never from the checkout they run in.
source "$(dirname "$0")/lib.sh"
CFG="$FACTORY_DIR/aghanim-config.sh"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export AGHANIM_HOME="$(mktemp -d)"

repo="$(new_repo)"
control="$AGHANIM_HOME/projects/shop/control"
git -C "$repo" worktree add -q --detach "$control"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$AGHANIM_HOME/projects/shop/factory.yml"   # the committed snapshot
mkdir -p "$repo/.mylos"; sed 's#acme/shop#evil/shop#' "$FACTORY_DIR/test/fixture/factory.yml" > "$repo/.mylos/factory.yml"
printf 'shop\t%s\t%s\n' "$repo" "$AGHANIM_HOME/projects/shop/wt" > "$AGHANIM_HOME/registry.tsv"

[ "$(cd "$repo" && bash "$CFG" get project.repo)" = "acme/shop" ] && pass "config comes from the project snapshot" \
  || fail "read $(cd "$repo" && bash "$CFG" get project.repo 2>&1)"
wt="$(mktemp -d)/7"; git -C "$repo" worktree add -q -b feat/7-x "$wt"
[ "$(cd "$wt" && bash "$CFG" get project.repo)" = "acme/shop" ] && pass "issue worktree resolves the same project" || fail "worktree did not resolve"
d="$(cd "$wt" && bash "$CFG" describe)"
assert_contains "$d" "projects/shop"
assert_contains "$d" "projects/shop/wt"

out="$(cd "$repo" && bash -c "source '$FACTORY_DIR/lib/project.sh'; aghanim_resolve && echo \"\$FACTORY_PROJECT|\$FACTORY_REPO\"")"
assert_contains "$out" "shop|"

cd "$(new_repo)"; assert_exit 2 bash "$CFG" get project.repo
cd "$(mktemp -d)"; assert_exit 2 bash "$CFG" get project.repo

# an explicit FACTORY_CONFIG wins over the registry
cd "$repo"; assert_contains "$(FACTORY_CONFIG="$repo/.mylos/factory.yml" bash "$CFG" get project.repo)" "evil/shop"
finish
