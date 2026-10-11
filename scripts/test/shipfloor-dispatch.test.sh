#!/usr/bin/env bash
# shipfloor-dispatch.sh runs one dispatch cycle per registered project, from that project's control
# checkout of origin/main, and skips only the projects it cannot use.
source "$(dirname "$0")/lib.sh"
MD="$FACTORY_DIR/shipfloor-dispatch.sh"
PY=python3; $PY -c '' 2>/dev/null || PY=python
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT

project() {  # project <slug> [config]: a repo with a remote whose main carries .shipfloor/factory.yml
  local slug="$1" cfg="${2:-}" remote r
  remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.shipfloor"
  if [ -n "$cfg" ]; then printf '%s\n' "$cfg" > "$r/.shipfloor/factory.yml"
  else sed "s/name: shop/name: $slug/" "$FACTORY_DIR/test/fixture/factory.yml" > "$r/.shipfloor/factory.yml"; fi
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$r" "$SHIPFLOOR_HOME/projects/$slug/wt" >> "$SHIPFLOOR_HOME/registry.tsv"
}
setup() {
  export SHIPFLOOR_HOME="$(mktemp -d)"; tmp="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "$FACTORY_PROJECT $PWD $FACTORY_CONFIG" >> "%s/ran"\n' "$tmp" > "$tmp/dispatch"
  chmod +x "$tmp/dispatch"; export SHIPFLOOR_DISPATCH="$tmp/dispatch"; : > "$tmp/ran"
}

setup; project shop; project blog
bash "$MD"; ran="$(cat "$tmp/ran")"
assert_contains "$ran" "shop "; assert_contains "$ran" "blog "
assert_contains "$ran" "projects/shop/factory.yml"
case "$ran" in *control/*) fail "config read from the editable control checkout" ;; *) pass "config outside the control checkout" ;; esac
[ -f "$SHIPFLOOR_HOME/projects/blog/control/.shipfloor/factory.yml" ] && pass "control checkout created" || fail "no control checkout"

# control follows origin/main and drops local edits
r="$(cut -f2 "$SHIPFLOOR_HOME/registry.tsv" | head -1)"
sed -i 's/number: 7/number: 8/' "$r/.shipfloor/factory.yml"; git -C "$r" commit -qam bump; git -C "$r" push -q origin main
echo tampered >> "$SHIPFLOOR_HOME/projects/shop/control/.shipfloor/factory.yml"
bash "$MD"; assert_contains "$(cat "$SHIPFLOOR_HOME/projects/shop/control/.shipfloor/factory.yml")" "number: 8"
case "$(cat "$SHIPFLOOR_HOME/projects/shop/control/.shipfloor/factory.yml")" in *tampered*) fail "kept a local edit" ;; *) pass "local edit dropped" ;; esac

# the gates' config is the committed one: an uncommitted edit in control (where runs work) is ignored
setup; project shop; export FACTORY_CONTROL_REFRESH=0; mkdir -p "$SHIPFLOOR_HOME/projects/shop"
r="$(cut -f2 "$SHIPFLOOR_HOME/registry.tsv")"; git -C "$r" worktree add -q --detach "$SHIPFLOOR_HOME/projects/shop/control" main
sed -i 's/number: 7/number: 99/' "$SHIPFLOOR_HOME/projects/shop/control/.shipfloor/factory.yml"
bash "$MD"; assert_contains "$(cat "$SHIPFLOOR_HOME/projects/shop/factory.yml")" "number: 7"
unset FACTORY_CONTROL_REFRESH

# global PAUSE stops everything; a project's PAUSE is honored by dispatch.sh itself
setup; project shop; touch "$SHIPFLOOR_HOME/PAUSE"; bash "$MD"
[ ! -s "$tmp/ran" ] && pass "global PAUSE" || fail "ran while paused: $(cat "$tmp/ran")"

# an invalid config skips only that project
setup; project broken 'project: {name: broken}'; project shop
out="$(bash "$MD" 2>&1)"; code=$?
ran="$(cat "$tmp/ran")"; assert_contains "$ran" "shop "
case "$ran" in *broken*) fail "dispatched an invalid project" ;; *) pass "invalid project skipped" ;; esac
assert_contains "$out" "broken"
[ "$code" -ne 0 ] && pass "cycle reports the failure" || fail "exit 0 with a broken project"

# a recent usage limit in any project pauses every launch
setup; project shop; project blog; mkdir -p "$SHIPFLOOR_HOME/projects/blog/logs"
printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit · resets 6pm\n' > "$SHIPFLOOR_HOME/projects/blog/logs/x-5-develop.log"
bash "$MD"; [ ! -s "$tmp/ran" ] && pass "usage limit pauses all projects" || fail "dispatched during a usage limit"

# an index.lock left behind by a dead git is removed (and named in the log), and the control catches up
setup; project shop; bash "$MD" >/dev/null 2>&1
r="$(cut -f2 "$SHIPFLOOR_HOME/registry.tsv")"; C="$SHIPFLOOR_HOME/projects/shop/control"
bump() { sed -i "s/number: [0-9]*/number: $1/" "$r/.shipfloor/factory.yml"; git -C "$r" commit -qam "bump $1"; git -C "$r" push -q origin main; }
lock="$(git -C "$C" rev-parse --absolute-git-dir)/index.lock"
bump 8; : > "$lock"; touch -d '30 minutes ago' "$lock"
out="$(bash "$MD" 2>&1)"
assert_contains "$out" "removed a stale index.lock"
assert_contains "$(cat "$C/.shipfloor/factory.yml")" "number: 8"
[ ! -e "$lock" ] && [ ! -e "$SHIPFLOOR_HOME/projects/shop/SKIPPED" ] && pass "stale lock cleared, project not skipped" || fail "stale lock left or project skipped"

# a lock that may still be held skips the project and says why where the dashboard looks;
# the first failed cycle's time is kept, and the next good cycle clears it
bump 9; : > "$lock"; : > "$tmp/ran"
out="$(SHIPFLOOR_LOCK_RETRY_S=0 bash "$MD" 2>&1)"
assert_contains "$out" "shop: cannot bring the control checkout"
[ ! -s "$tmp/ran" ] && pass "skipped project not dispatched" || fail "dispatched a project it could not refresh"
S="$SHIPFLOOR_HOME/projects/shop/SKIPPED"; assert_contains "$(cat "$S" 2>/dev/null)" "index.lock"
printf '2026-10-09T20:06:50-03:00\t%s\n' "$(cut -f2 "$S")" > "$S"
SHIPFLOOR_LOCK_RETRY_S=0 bash "$MD" >/dev/null 2>&1
assert_contains "$(cut -f1 "$S")" "2026-10-09T20:06:50"
rm -f "$lock"; bash "$MD" >/dev/null 2>&1
[ ! -e "$S" ] && pass "a good cycle clears the skip" || fail "SKIPPED kept after a good cycle: $(cat "$S")"
assert_contains "$(cat "$C/.shipfloor/factory.yml")" "number: 9"

# a run left files with very long paths in the control checkout (node_modules on Windows, past 260
# characters): the refresh still cleans them instead of skipping the project on every cycle
setup; project shop; bash "$MD" >/dev/null 2>&1
r="$(cut -f2 "$SHIPFLOOR_HOME/registry.tsv")"; C="$SHIPFLOOR_HOME/projects/shop/control"
"$PY" -I - "$(nat "$C")" <<'PYEOF'
import os, sys
deep = os.path.join(os.path.abspath(sys.argv[1]), "node_modules", *(["a-rather-long-directory-name-0123456789"] * 8))
if os.name == "nt":
    deep = "\\\\?\\" + deep
os.makedirs(deep, exist_ok=True)
open(os.path.join(deep, "left-by-a-run.js"), "w").close()
PYEOF
sed -i "s/number: [0-9]*/number: 12/" "$r/.shipfloor/factory.yml"; git -C "$r" commit -qam "bump 12"; git -C "$r" push -q origin main
out="$(SHIPFLOOR_LOCK_RETRY_S=0 bash "$MD" 2>&1)"
[ ! -e "$C/node_modules" ] && [ ! -e "$SHIPFLOOR_HOME/projects/shop/SKIPPED" ] && pass "long paths cleaned from the control checkout" || fail "long paths left in control: $out"
assert_contains "$(cat "$C/.shipfloor/factory.yml")" "number: 12"

# no registry → nothing to do, no error
setup; assert_exit 0 bash "$MD"
finish
