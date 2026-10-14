#!/usr/bin/env bash
# deploy.sh merging the PR and checking production: gh pr merge failing, an unknown merge commit, the CI run on main,
# each deploy.environment outcome, health checks, the revert (and when it cannot be prepared), a revert/<n> PR being
# deployed, the worktree and the Deployed comment. Exit code and what the fake gh recorded.
source "$(dirname "$0")/deploy-lib.sh"
export FAKE_GH="$FACTORY_DIR/test/fake-gh-deploy"
gh_with() {  # gh_with '<shell>': the fake gh behind a snippet that may answer a call itself (L logs it) or let it through
  printf '#!/usr/bin/env bash\nL() { echo "$*" >> "$FG/calls"; }\n%s\nexec bash "%s" "$@"\n' "$1" "$FAKE_GH" > "$T/gh"
  chmod +x "$T/gh"; export FACTORY_GH="$T/gh"
}
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out")"; }
posted() { case "$(cat "$FG/calls" 2>/dev/null)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
dcfg() { sed -i '/^deploy:/d' "$FACTORY_CONFIG"; printf 'deploy: %s\n' "$1" >> "$FACTORY_CONFIG"; }
on_main() { git --git-dir="$remote" cat-file -e "main:$1" 2>/dev/null; }
reverted() {  # reverted <label> <reason>: exit 6, the revert PR opened, the reason on the card, reopened and blocked
  want "$code" 6 "$1 → failed after merge"
  assert_contains "$(cat "$FG/comments")" "Production deploy failed: $2"
  assert_contains "$(cat "$FG/comments")" "Revert PR: https://github.com/acme/shop/pull/999"
  assert_contains "$(cat "$FG/comments")" "staged-head: $(git --git-dir="$remote" rev-parse refs/heads/revert/7)"
  assert_contains "$(cat "$FG/calls")" "pr create"
  assert_contains "$(cat "$FG/labels")" reopened
  assert_contains "$(cat "$FG/labels")" blocked
  [ "$(cat "$FG/status")" != Done ] && pass "$1: card not Done" || fail "card in Done"
  [ ! -e "$FACTORY_WT_ROOT/revert-7" ] && pass "$1: revert worktree removed" || fail "revert worktree left"
  [ -e "$FACTORY_WT_ROOT/7/.git" ] && pass "$1: card worktree kept" || fail "card worktree removed"
}
shipped() {  # shipped <label>: Done, the Deployed comment, the card's worktree gone
  want "$code" 0 "$1 → exit 0"
  [ "$(cat "$FG/status")" = Done ] && pass "$1: card in Done" || fail "status $(cat "$FG/status")"
  assert_contains "$(cat "$FG/comments")" "Deployed: merge $(cat "$FG/merged")"
  [ ! -e "$FACTORY_WT_ROOT/7" ] && pass "$1: worktree removed" || fail "worktree left"
  case "$(git -C "$repo" worktree list)" in *"/7 "*) fail "$1: worktree still registered" ;; *) pass "$1: worktree unregistered" ;; esac
  [ ! -e "$FG/labels" ] && pass "$1: not labelled" || fail "labelled: $(cat "$FG/labels")"
}

# AC-6, gh pr merge: fails but the PR is MERGED (GitHub merged it, the answer was lost) → accepted, shipped
setup; gh_with 'case "$*" in "pr merge"*) bash "$FAKE_GH" "$@" >/dev/null 2>&1; exit 1 ;; esac'
code="$(run 7)"; shipped "pr merge failing with state MERGED"
posted "pr merge" && pass "pr merge was tried" || fail "no pr merge"
on_main api/A.kt && pass "card is on main" || fail "not on main"
# ...but still OPEN → blocked with the end of gh's own message
setup; gh_with 'case "$*" in "pr merge"*) L "$*"; echo "merge queue refused it" >&2; exit 1 ;; esac'
code="$(run 7)"; want "$code" 5 "pr merge failing, PR open → blocked"
assert_contains "$(cat "$FG/comments")" "Factory deploy stopped: gh pr merge failed: merge queue refused it"
assert_contains "$(cat "$FG/labels")" blocked
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "refused merge: card not moved" || fail "status $(cat "$FG/status")"
on_main api/A.kt && fail "merged anyway" || pass "refused merge: nothing on main"

# the merge commit never becomes known → exit 2, nothing said; the next run resumes at production
setup; gh_with 'case "$*" in "pr view"*mergeCommit*) L "$*"; exit 0 ;; esac'
code="$(run 7)"; want "$code" 2 "unknown merge commit → retry later"
assert_contains "$(cat "$T/out")" "merged but its merge commit is not known yet; will retry"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "unknown merge commit: card not moved" || fail "status $(cat "$FG/status")"
case "$(cat "$FG/comments")" in *Deployed*|*"Production deploy failed"*) fail "said something on an unknown merge" ;; *) pass "unknown merge commit: no comment" ;; esac
[ ! -e "$FG/labels" ] && pass "unknown merge commit: not labelled" || fail "labelled"
[ "$(grep -c 'pr view 78.*mergeCommit' "$FG/calls")" = 10 ] && pass "asked ten times" || fail "asked $(grep -c 'pr view 78.*mergeCommit' "$FG/calls") times"
export FACTORY_GH="$FAKE_GH"; code="$(run 7)"; shipped "the run after an unknown merge commit"
setup; gh_with 'case "$*" in "pr view"*mergeCommit*) L "$*"; echo abc123; exit 0 ;; esac'
code="$(run 7)"; want "$code" 2 "merge commit that is not a sha → retry later"

# production CI (deploy.ci_workflow): no run found for the merge commit → reverted
setup; dcfg '{ci_workflow: CI}'; code="$(run 7)"
reverted "no CI run on main" "no 'CI' run on main for $(cat "$FG/merged")"
on_main api/A.kt && pass "no CI run: the card stays on main until the revert PR merges" || fail "the revert landed on main by itself"
# a run that does not finish
setup; dcfg '{ci_workflow: CI}'; echo "in_progress " > "$FG/concl-1"; gh_with 'case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; esac'
code="$(FACTORY_POLLS=3 run 7)"; reverted "CI run that does not finish" "CI on main did not finish (run 1)"
# a failed run whose failed jobs fail again: reverted, with the end of the failed log on the card
setup; dcfg '{ci_workflow: CI}'; echo "completed failure" > "$FG/concl-1"; echo "completed failure" > "$FG/rerun-1"
gh_with 'case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; "run view"*--log-failed*) L "$*"; echo "FAILED LOG: boom in step 3"; exit 0 ;; esac'
code="$(run 7)"; reverted "CI run failing again on the rerun" "CI on main failed (run 1: failure)"
assert_contains "$(cat "$FG/comments")" "The end of the log of the failed run:"
assert_contains "$(cat "$FG/comments")" "FAILED LOG: boom in step 3"
[ "$(grep -c 'run rerun 1' "$FG/calls")" = 1 ] && pass "rerun asked once" || fail "reruns: $(grep -c 'run rerun 1' "$FG/calls")"
assert_contains "$(cat "$T/out")" "running its failed jobs once more"
# a failed run that cannot be rerun is reverted at once
setup; dcfg '{ci_workflow: CI}'; echo "completed failure" > "$FG/concl-1"
gh_with 'case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; "run rerun"*) L "$*"; exit 1 ;; "run view"*--log-failed*) L "$*"; echo "NO RERUN LOG"; exit 0 ;; esac'
code="$(run 7)"; reverted "CI run that cannot be rerun" "CI on main failed (run 1: failure)"
assert_contains "$(cat "$FG/comments")" "NO RERUN LOG"
case "$(cat "$T/out")" in *"once more"*) fail "claimed a rerun" ;; *) pass "no rerun claimed" ;; esac
# a green run ships
setup; dcfg '{ci_workflow: CI}'; echo "completed success" > "$FG/concl-1"; gh_with 'case "$*" in "run list"*--workflow*) L "$*"; echo 1; exit 0 ;; esac'
code="$(run 7)"; shipped "green CI run on main"

# deploy.environment: success with a URL → Deployed carries the URL and the minutes
env_gh() { gh_with 'case "$*" in
  "api repos/"*"deployments?sha="*) L "$*"; [ -e "$FG/dep-id" ] && cat "$FG/dep-id"; exit 0 ;;
  "api repos/"*"/statuses"*) L "$*"; case "$*" in *environment_url*) cat "$FG/dep-url" 2>/dev/null ;; *) cat "$FG/dep-state" 2>/dev/null ;; esac; exit 0 ;;
esac'; }
setup; dcfg '{environment: production}'; env_gh; echo 5 > "$FG/dep-id"; echo success > "$FG/dep-state"; echo "https://prod.example/app" > "$FG/dep-url"
code="$(run 7)"; shipped "environment success"
assert_contains "$(cat "$FG/comments")" "Deployed: merge $(cat "$FG/merged") · https://prod.example/app · "
assert_contains "$(cat "$FG/comments")" " min from the start of this deploy run."
assert_contains "$(cat "$FG/calls")" "deployments?sha=$(cat "$FG/merged")"
# inactive: superseded by a newer deployment, which is as good as success (no URL)
setup; dcfg '{environment: production}'; env_gh; echo 5 > "$FG/dep-id"; echo inactive > "$FG/dep-state"
code="$(run 7)"; shipped "environment inactive"
assert_contains "$(cat "$T/out")" "deployment 5 superseded by a newer one"
case "$(cat "$FG/comments")" in *http*) fail "a URL on a superseded deployment" ;; *) pass "no URL on a superseded deployment" ;; esac
# failure and error end the wait at once; a deployment that never appears or stays pending ends in a timeout
for st in failure error; do
  setup; dcfg '{environment: production}'; env_gh; echo 5 > "$FG/dep-id"; echo "$st" > "$FG/dep-state"
  code="$(run 7)"; reverted "environment $st" "deployment to 'production' ended '$st'"
done
setup; dcfg '{environment: production}'; env_gh; code="$(FACTORY_POLLS=3 run 7)"
reverted "environment that never appears" "deployment to 'production' ended 'timeout'"
setup; dcfg '{environment: production}'; env_gh; echo null > "$FG/dep-id"; code="$(FACTORY_POLLS=3 run 7)"
reverted "environment with a null id" "deployment to 'production' ended 'timeout'"
setup; dcfg '{environment: production}'; env_gh; echo 5 > "$FG/dep-id"; echo pending > "$FG/dep-state"; code="$(FACTORY_POLLS=3 run 7)"
reverted "environment that stays pending" "deployment to 'production' ended 'pending'"

# several health check URLs: all are asked, in order; the first that fails reverts and the rest are not asked
curl_log() {  # curl_log <pattern>: a curl that records its URL and fails for the URLs matching <pattern>
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/curled"\ncase "$*" in *%s*) exit 22 ;; esac\nexit 0\n' "$FG" "$1" > "$T/curl"; chmod +x "$T/curl"
}
HC='{healthcheck: ["https://a.example/health", "https://b.example/health", "https://c.example/health"]}'
setup; dcfg "$HC"; curl_log NOPE; code="$(run 7)"; shipped "three healthy URLs"
for u in a b c; do [ "$(grep -c "https://$u.example/health" "$FG/curled")" = 1 ] && pass "$u asked once" || fail "$u asked $(grep -c "https://$u.example/health" "$FG/curled")"; done
setup; dcfg "$HC"; curl_log b.example; code="$(run 7)"; reverted "second URL unhealthy" "health check failed: https://b.example/health"
[ "$(grep -c 'https://a.example/health' "$FG/curled")" = 1 ] && pass "a asked once" || fail "a asked $(grep -c 'https://a.example/health' "$FG/curled")"
[ "$(grep -c 'https://b.example/health' "$FG/curled")" = 5 ] && pass "b tried five times" || fail "b tried $(grep -c 'https://b.example/health' "$FG/curled")"
grep -q 'https://c.example/health' "$FG/curled" && fail "c asked after b failed" || pass "c not asked"

# preparing the revert fails (revert/7 already exists and diverged) → "revert by hand", no PR
setup; echo 22 > "$FG/curl"; git -C "$repo" push -q origin feat/7-x:refs/heads/revert/7; theirs="$(git --git-dir="$remote" rev-parse refs/heads/revert/7)"
code="$(run 7)"; want "$code" 6 "revert branch already exists → failed after merge"
assert_contains "$(cat "$FG/comments")" "Production deploy failed: health check failed: https://shop.example/health. The revert could not be prepared automatically: revert $(cat "$FG/merged") by hand."
posted "pr create" && fail "opened a PR for a revert not prepared" || pass "no pr create"
assert_contains "$(cat "$FG/labels")" reopened
assert_contains "$(cat "$FG/labels")" blocked
[ "$(git --git-dir="$remote" rev-parse refs/heads/revert/7)" = "$theirs" ] && pass "existing revert branch untouched" || fail "revert branch overwritten"
case "$(cat "$FG/comments")" in *"Revert PR:"*) fail "named a revert PR" ;; *) pass "no Revert PR on the card" ;; esac
# pr create fails after the branch was pushed → the card says so
setup; echo 22 > "$FG/curl"; gh_with 'case "$*" in "pr create"*) L "$*"; exit 1 ;; esac'
code="$(run 7)"; want "$code" 6 "pr create fails → failed after merge"
assert_contains "$(cat "$FG/comments")" "Revert PR: (revert branch revert/7 pushed; opening its PR failed)"
assert_contains "$(cat "$FG/comments")" "staged-head: $(git --git-dir="$remote" rev-parse refs/heads/revert/7)"
assert_contains "$(cat "$FG/labels")" reopened
assert_contains "$(cat "$FG/labels")" blocked
git --git-dir="$remote" rev-parse -q --verify refs/heads/revert/7 >/dev/null && pass "revert branch pushed" || fail "no revert branch"

# a revert/7 PR deployed itself: the card is reopened, the owner moves it back, only the forbidden-path gate runs
setup; echo 22 > "$FG/curl"; run 7 >/dev/null; rhead="$(git --git-dir="$remote" rev-parse refs/heads/revert/7)"
rm -f "$FG/merged" "$FG/curl" "$FG/labels"; echo 999 > "$FG/pr"; echo revert/7 > "$FG/branch"; echo "Ready for Prod" > "$FG/status"; : > "$FG/calls"
code="$(run 7)"; want "$code" 0 "revert/7 PR deployed → exit 0"
[ "$(cat "$FG/status")" = Done ] && pass "revert PR: card in Done" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/calls")" "pr merge 999"
assert_contains "$(cat "$FG/calls")" "--match-head-commit $rhead"
on_main api/A.kt && fail "the revert did not remove the card from main" || pass "revert PR merged: the card is off main"
assert_contains "$(cat "$FG/comments")" "Deployed: merge $(cat "$FG/merged")"
[ ! -e "$FACTORY_WT_ROOT/7" ] && pass "revert PR: worktree removed" || fail "worktree left"
assert_contains "$(cat "$FACTORY_HOME/tmp/7/gates.txt")" "forbidden"
case "$(cat "$FACTORY_HOME/tmp/7/gates.txt")" in *"acceptance"*|*"scope"*|*"migration"*|*"build"*) fail "more than the forbidden-path gate ran: $(cat "$FACTORY_HOME/tmp/7/gates.txt")" ;; *) pass "only the forbidden-path gate ran" ;; esac

# the worktree goes with Done, the Deployed comment names the merge and the minutes
setup; code="$(run 7)"; shipped "plain deploy"
assert_contains "$(cat "$FG/comments")" "Deployed: merge $(cat "$FG/merged") · "
finish
