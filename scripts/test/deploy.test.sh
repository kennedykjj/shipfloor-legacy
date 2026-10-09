#!/usr/bin/env bash
# deploy.sh: the whole deploy as a script; the model only resolves conflicts it hands over.
source "$(dirname "$0")/lib.sh"
DEP="$FACTORY_DIR/deploy.sh"
M=api/src/main/resources/db/migration

setup() {  # a project with main and a staged card #7 on feat/7-x
  T="$(mktemp -d)"; export FG="$T/fg"; mkdir -p "$FG"
  remote="$T/remote.git"; git init -q --bare "$remote"; echo "$remote" > "$FG/remote"
  echo 78 > "$FG/pr"; echo feat/7-x > "$FG/branch"; echo "api=SUCCESS" > "$FG/ci"; : > "$FG/comments"
  repo="$(new_repo)"; git -C "$repo" remote add origin "$remote"
  mkdir -p "$repo/$M" "$repo/docs/superpowers/specs"; echo 'create table a (id int);' > "$repo/$M/V1__a.sql"
  printf '# x\n\n## Rollback\n\nn/a\n' > "$repo/docs/superpowers/specs/2026-01-01-x-design.md"
  echo shared > "$repo/shared.txt"
  git -C "$repo" add -A; git -C "$repo" commit -qm main; git -C "$repo" push -q origin main
  git -C "$repo" checkout -qb feat/7-x
  mkdir -p "$repo/api/src/test"; echo test > "$repo/api/src/test/ATest.kt"; git -C "$repo" add -A; git -C "$repo" commit -qm "test(x): acceptance tests for #7"
  echo impl > "$repo/api/A.kt"; git -C "$repo" add -A; git -C "$repo" commit -qm "feat(x): impl"
  git -C "$repo" push -q origin feat/7-x; git -C "$repo" checkout -q main
  printf 'factory	staged-head: %s
' "$(git -C "$repo" rev-parse feat/7-x)" >> "$FG/comments"
  printf '#!/usr/bin/env bash\ncase "$1" in status) cat "%s/status" ;; move) echo "$3" > "%s/status" ;; esac\n' "$FG" "$FG" > "$T/board"
  chmod +x "$T/board"; echo "Ready for Prod" > "$FG/status"
  printf '#!/usr/bin/env bash\nexit "$(cat "%s/curl" 2>/dev/null || echo 0)"\n' "$FG" > "$T/curl"; chmod +x "$T/curl"
  export FACTORY_CONFIG="$T/factory.yml"
  cat "$FACTORY_DIR/test/fixture/factory.yml" | sed '/^deploy:/d' > "$FACTORY_CONFIG"
  echo 'deploy: {healthcheck: ["https://shop.example/health"]}' >> "$FACTORY_CONFIG"
  export FACTORY_HOME="$T/home" FACTORY_WT_ROOT="$T/wt" FACTORY_REPO="$repo" FACTORY_GH="$FACTORY_DIR/test/fake-gh-deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CURL="$T/curl" FACTORY_POLL=0
  mkdir -p "$FACTORY_HOME"
}
main_commit() {  # main_commit <file> <content>: another card lands on main
  local w; w="$(mktemp -d)"; git clone -q "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
  mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" > "$w/$1"; git -C "$w" add -A; git -C "$w" commit -qm "main: $1"; git -C "$w" push -q origin main
}
on_branch() {  # on_branch <file> <content>: a commit on the card's branch (then re-staged)
  local w; w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
  mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" > "$w/$1"; git -C "$w" add -A; git -C "$w" commit -qm "card: $1"; git -C "$w" push -q origin feat/7-x
  printf 'factory	staged-head: %s
' "$(git -C "$w" rev-parse HEAD)" >> "$FG/comments"
}
run() { (cd "$repo" && bash "$DEP" "$@" > "$T/out" 2>&1); echo $?; }

# up to date head: merged, health checked, Done
setup; code="$(run 7)"; [ "$code" = 0 ] && pass "deploy done" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = Done ] && pass "card in Done" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "Deployed: merge"
git --git-dir="$remote" show main:api/A.kt >/dev/null 2>&1 && pass "squashed into main" || fail "not on main"

# behind main: merges main into the PR, pushes, records deploy-merge, then deploys
setup; main_commit web/other.ts x; code="$(run 7)"; [ "$code" = 0 ] && pass "deploy after updating" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "

# a migration conflicting with main → back to Coding, nothing pushed
setup; on_branch "$M/V2__card.sql" card; main_commit "$M/V2__card.sql" main
before="$(git --git-dir="$remote" rev-parse feat/7-x)"; code="$(run 7)"
[ "$code" = 4 ] && pass "migration conflict → back to Coding" || fail "exit $code: $(cat "$T/out")"
[ "$(cat "$FG/status")" = Coding ] && pass "card in Coding" || fail "status $(cat "$FG/status")"
[ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "nothing pushed" || fail "pushed a failed merge"
[ -z "$(git -C "$FACTORY_WT_ROOT/7" status --porcelain)" ] && pass "worktree left clean" || fail "worktree dirty"

# a small conflict → handed over (exit 3); after it is resolved, --continue finishes
setup; on_branch shared.txt card; main_commit shared.txt main; code="$(run 7)"
[ "$code" = 3 ] && pass "small conflict handed over" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$T/out")" "CONFLICT shared.txt"
echo resolved > "$FACTORY_WT_ROOT/7/shared.txt"; git -C "$FACTORY_WT_ROOT/7" add shared.txt; git -C "$FACTORY_WT_ROOT/7" commit -q --no-edit
code="$(run 7 --continue)"; [ "$code" = 0 ] && pass "--continue deploys" || fail "exit $code: $(cat "$T/out")"

# a head nobody approved → blocked
setup; w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
echo sneaky > "$w/api/B.kt"; git -C "$w" add -A; git -C "$w" commit -qm sneaky; git -C "$w" push -q origin feat/7-x
code="$(run 7)"; [ "$code" = 5 ] && pass "unapproved head blocked" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/labels")" blocked

# red CI after merging main → back to Coding
setup; main_commit web/other.ts x; echo "api=FAILURE" > "$FG/ci"; code="$(run 7)"
[ "$code" = 4 ] && pass "red CI after merge → Coding" || fail "exit $code: $(cat "$T/out")"

# failed health check after merge → revert PR, reopened, blocked
setup; echo 22 > "$FG/curl"; code="$(run 7)"
[ "$code" = 6 ] && pass "failed health check → revert" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/calls")" "pr create"
assert_contains "$(cat "$FG/labels")" reopened
git --git-dir="$remote" rev-parse -q --verify refs/heads/revert/7 >/dev/null && pass "revert branch pushed" || fail "no revert branch"

# refresh: behind main → pushed and recorded, card stays Staged; conflict → untouched
setup; echo Staged > "$FG/status"; main_commit web/other.ts x; code="$(run 7 --refresh)"
[ "$code" = 0 ] && [ "$(cat "$FG/status")" = Staged ] && pass "refresh keeps the card staged" || fail "exit $code / $(cat "$FG/status"): $(cat "$T/out")"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "
case "$(cat "$FG/calls")" in *"pr merge"*) fail "refresh merged the PR" ;; *) pass "refresh never merges" ;; esac
setup; echo Staged > "$FG/status"; on_branch shared.txt card; main_commit shared.txt main; before="$(git --git-dir="$remote" rev-parse feat/7-x)"
code="$(run 7 --refresh)"; [ "$code" = 0 ] && [ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "refresh leaves conflicts to the deploy" || fail "exit $code: $(cat "$T/out")"

# the PR head GitHub reports is not what the branch holds (a push mid-run) → retry later, never merge
setup; echo 0123456789012345678901234567890123456789 > "$FG/prhead"; code="$(run 7)"
[ "$code" = 2 ] && pass "head mismatch → retry" || fail "exit $code: $(cat "$T/out")"
case "$(cat "$FG/calls")" in *"pr merge"*) fail "merged on a head mismatch" ;; *) pass "no merge on a head mismatch" ;; esac
setup; : > "$FG/prhead"; code="$(run 7)"; [ "$code" = 2 ] && pass "empty head → retry" || fail "exit $code"

# only the factory's own comments approve
setup; w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
echo evil > "$w/api/E.kt"; git -C "$w" add -A; git -C "$w" commit -qm evil; git -C "$w" push -q origin feat/7-x
printf 'mallory\tstaged-head: %s\n' "$(git -C "$w" rev-parse HEAD)" >> "$FG/comments"
code="$(run 7)"; [ "$code" = 5 ] && pass "forged staged-head ignored" || fail "exit $code: $(cat "$T/out")"

# a modify/delete conflict (no markers) is handled, not a crash
setup; on_branch shared.txt card; w="$(mktemp -d)"; git clone -q "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
git -C "$w" rm -q shared.txt; git -C "$w" commit -qm "main: drop shared"; git -C "$w" push -q origin main
code="$(run 7)"; [ "$code" = 3 ] && pass "modify/delete conflict handed over" || fail "exit $code: $(cat "$T/out")"

# no open PR while the worktree exists → blocked with a comment (not a crash)
setup; run 7 >/dev/null; setup; mkdir -p "$FACTORY_WT_ROOT"; git -C "$repo" worktree add -q "$FACTORY_WT_ROOT/7" feat/7-x; touch "$FG/no-pr"
code="$(run 7)"; [ "$code" = 5 ] && pass "missing PR → blocked" || fail "exit $code: $(cat "$T/out")"

# a run that stopped after merging resumes at production
setup; run 7 >/dev/null; echo "Ready for Prod" > "$FG/status"; : > "$FG/calls"
code="$(run 7)"; [ "$code" = 0 ] && [ "$(cat "$FG/status")" = Done ] && pass "resumes after the merge" || fail "exit $code: $(cat "$T/out")"
case "$(cat "$FG/calls")" in *"pr merge"*) fail "merged twice" ;; *) pass "no second merge" ;; esac

# --continue refuses a resolution that changes files that did not conflict
setup; on_branch shared.txt card; main_commit shared.txt main; run 7 >/dev/null
echo resolved > "$FACTORY_WT_ROOT/7/shared.txt"; echo sneaky > "$FACTORY_WT_ROOT/7/api/A.kt"
git -C "$FACTORY_WT_ROOT/7" add -A; git -C "$FACTORY_WT_ROOT/7" commit -q --no-edit
code="$(run 7 --continue)"; [ "$code" = 5 ] && pass "tampered resolution blocked" || fail "exit $code: $(cat "$T/out")"

# checks still pending keep waiting; a required check that never reports is not green
setup; printf 'deploy: {required_checks: [api, web]}\n' >> "$FACTORY_CONFIG"; sed -i '/healthcheck/d' "$FACTORY_CONFIG"
code="$(run 7)"; [ "$code" = 5 ] && pass "missing required check → not merged" || fail "exit $code: $(cat "$T/out")"
finish
