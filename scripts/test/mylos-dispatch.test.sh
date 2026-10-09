#!/usr/bin/env bash
# mylos-dispatch.sh runs one dispatch cycle per registered project, from that project's control
# checkout of origin/main, and skips only the projects it cannot use.
source "$(dirname "$0")/lib.sh"
MD="$FACTORY_DIR/mylos-dispatch.sh"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT

project() {  # project <slug> [config]: a repo with a remote whose main carries .mylos/factory.yml
  local slug="$1" cfg="${2:-}" remote r
  remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.mylos"
  if [ -n "$cfg" ]; then printf '%s\n' "$cfg" > "$r/.mylos/factory.yml"
  else sed "s/name: shop/name: $slug/" "$FACTORY_DIR/test/fixture/factory.yml" > "$r/.mylos/factory.yml"; fi
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$r" "$MYLOS_HOME/projects/$slug/wt" >> "$MYLOS_HOME/registry.tsv"
}
setup() {
  export MYLOS_HOME="$(mktemp -d)"; tmp="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "$FACTORY_PROJECT $PWD $FACTORY_CONFIG" >> "%s/ran"\n' "$tmp" > "$tmp/dispatch"
  chmod +x "$tmp/dispatch"; export MYLOS_DISPATCH="$tmp/dispatch"; : > "$tmp/ran"
}

setup; project shop; project blog
bash "$MD"; ran="$(cat "$tmp/ran")"
assert_contains "$ran" "shop "; assert_contains "$ran" "blog "
assert_contains "$ran" "projects/shop/factory.yml"
case "$ran" in *control/*) fail "config read from the editable control checkout" ;; *) pass "config outside the control checkout" ;; esac
[ -f "$MYLOS_HOME/projects/blog/control/.mylos/factory.yml" ] && pass "control checkout created" || fail "no control checkout"

# control follows origin/main and drops local edits
r="$(cut -f2 "$MYLOS_HOME/registry.tsv" | head -1)"
sed -i 's/number: 7/number: 8/' "$r/.mylos/factory.yml"; git -C "$r" commit -qam bump; git -C "$r" push -q origin main
echo tampered >> "$MYLOS_HOME/projects/shop/control/.mylos/factory.yml"
bash "$MD"; assert_contains "$(cat "$MYLOS_HOME/projects/shop/control/.mylos/factory.yml")" "number: 8"
case "$(cat "$MYLOS_HOME/projects/shop/control/.mylos/factory.yml")" in *tampered*) fail "kept a local edit" ;; *) pass "local edit dropped" ;; esac

# the gates' config is the committed one: an uncommitted edit in control (where runs work) is ignored
setup; project shop; export FACTORY_CONTROL_REFRESH=0; mkdir -p "$MYLOS_HOME/projects/shop"
r="$(cut -f2 "$MYLOS_HOME/registry.tsv")"; git -C "$r" worktree add -q --detach "$MYLOS_HOME/projects/shop/control" main
sed -i 's/number: 7/number: 99/' "$MYLOS_HOME/projects/shop/control/.mylos/factory.yml"
bash "$MD"; assert_contains "$(cat "$MYLOS_HOME/projects/shop/factory.yml")" "number: 7"
unset FACTORY_CONTROL_REFRESH

# global PAUSE stops everything; a project's PAUSE is honored by dispatch.sh itself
setup; project shop; touch "$MYLOS_HOME/PAUSE"; bash "$MD"
[ ! -s "$tmp/ran" ] && pass "global PAUSE" || fail "ran while paused: $(cat "$tmp/ran")"

# an invalid config skips only that project
setup; project broken 'project: {name: broken}'; project shop
out="$(bash "$MD" 2>&1)"; code=$?
ran="$(cat "$tmp/ran")"; assert_contains "$ran" "shop "
case "$ran" in *broken*) fail "dispatched an invalid project" ;; *) pass "invalid project skipped" ;; esac
assert_contains "$out" "broken"
[ "$code" -ne 0 ] && pass "cycle reports the failure" || fail "exit 0 with a broken project"

# a recent usage limit in any project pauses every launch
setup; project shop; project blog; mkdir -p "$MYLOS_HOME/projects/blog/logs"
printf '== start /mylos:develop 5\nYou'"'"'ve hit your session limit · resets 6pm\n' > "$MYLOS_HOME/projects/blog/logs/x-5-develop.log"
bash "$MD"; [ ! -s "$tmp/ran" ] && pass "usage limit pauses all projects" || fail "dispatched during a usage limit"

# no registry → nothing to do, no error
setup; assert_exit 0 bash "$MD"
finish
