#!/usr/bin/env bash
# deploy.sh, the start of a run: the lock, the column, --refresh, forks, several PRs, a merged PR missing from main.
# Every case checks the exit code and what the fake gh and the board recorded (comments, labels, calls, status).
source "$(dirname "$0")/deploy-lib.sh"
export FAKE_GH="$FACTORY_DIR/test/fake-gh-deploy"
gh_with() {  # gh_with '<shell>': the fake gh behind a snippet that may answer a call itself (L logs it) or let it through
  printf '#!/usr/bin/env bash\nL() { echo "$*" >> "$FG/calls"; }\n%s\nexec bash "%s" "$@"\n' "$1" "$FAKE_GH" > "$T/gh"
  chmod +x "$T/gh"; export FACTORY_GH="$T/gh"
}
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out")"; }
untouched() {  # untouched <comments before>: nothing was said, labelled or moved on the card
  cmp -s "$1" "$FG/comments" && pass "no comment posted" || fail "comments changed: $(cat "$FG/comments")"
  [ ! -e "$FG/labels" ] && pass "no label" || fail "labelled: $(cat "$FG/labels")"
}
posted() { case "$(cat "$FG/calls" 2>/dev/null)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# AC-1: a busy lock (a live pid) → exit 2, nothing asked of GitHub, the lock stays with its owner
setup; mkdir -p "$FACTORY_HOME/locks/deploysh-7.lock"; echo "$$ 0" > "$FACTORY_HOME/locks/deploysh-7.lock/info"
cp "$FG/comments" "$T/before"; code="$(run 7)"
want "$code" 2 "busy lock → exit 2"
assert_contains "$(cat "$T/out")" "another deploy.sh runs on this card (pid $$)"
[ ! -s "$FG/calls" ] && pass "busy lock: gh not called" || fail "gh called: $(cat "$FG/calls")"
[ -d "$FACTORY_HOME/locks/deploysh-7.lock" ] && pass "busy lock: left to its owner" || fail "lock removed"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "busy lock: card not moved" || fail "status $(cat "$FG/status")"
untouched "$T/before"

# a stale lock (the pid is gone) is taken over and the deploy goes on; the lock is gone at the end
setup; sleep 0 & dead=$!; wait "$dead"; mkdir -p "$FACTORY_HOME/locks/deploysh-7.lock"; echo "$dead 0" > "$FACTORY_HOME/locks/deploysh-7.lock/info"
code="$(run 7)"
want "$code" 0 "stale lock → taken over, deployed"
[ "$(cat "$FG/status")" = Done ] && pass "stale lock: card in Done" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "Deployed: merge"
[ ! -e "$FACTORY_HOME/locks/deploysh-7.lock" ] && pass "stale lock: released at the end" || fail "lock left behind"
# a lock with no info at all is as good as stale
setup; mkdir -p "$FACTORY_HOME/locks/deploysh-7.lock"; code="$(run 7)"
want "$code" 0 "lock without info → taken over"
[ "$(cat "$FG/status")" = Done ] && pass "lock without info: card in Done" || fail "status $(cat "$FG/status")"

# the card is in the wrong column → exit 2 before gh is asked anything
for col in Staged Coding "In Progress" Done; do
  setup; echo "$col" > "$FG/status"; cp "$FG/comments" "$T/before"; code="$(run 7)"
  want "$code" 2 "card in $col → exit 2"
  assert_contains "$(cat "$T/out")" "#7 is in '$col', not Ready for Prod"
  [ ! -s "$FG/calls" ] && pass "$col: gh not called" || fail "gh called: $(cat "$FG/calls")"
  [ "$(cat "$FG/status")" = "$col" ] && pass "$col: card not moved" || fail "status $(cat "$FG/status")"
  untouched "$T/before"
done
# an argument that is not a card number, or a mode that does not exist, is a usage error
setup; code="$(run x)"; want "$code" 2 "bad card number → exit 2"
assert_contains "$(cat "$T/out")" "usage: deploy.sh <n> [--refresh | --continue]"
setup; code="$(run 7 --bogus)"; want "$code" 2 "unknown mode → exit 2"
[ ! -s "$FG/calls" ] && pass "usage error: gh not called" || fail "gh called"

# --refresh on a card that is not Staged → exit 0, nothing moved
setup; cp "$FG/comments" "$T/before"; code="$(run 7 --refresh)"
want "$code" 0 "--refresh on a card in Ready for Prod → exit 0"
assert_contains "$(cat "$T/out")" "not Staged (Ready for Prod); nothing to refresh"
[ ! -s "$FG/calls" ] && pass "refresh not Staged: gh not called" || fail "gh called: $(cat "$FG/calls")"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "refresh not Staged: card not moved" || fail "status $(cat "$FG/status")"
untouched "$T/before"

# --refresh on a head nobody approved → exit 0, nothing pushed, nothing said
setup; echo Staged > "$FG/status"; main_commit web/other.ts x
w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
echo sneaky > "$w/api/B.kt"; git -C "$w" add -A; git -C "$w" commit -qm sneaky; git -C "$w" push -q origin feat/7-x
before="$(git --git-dir="$remote" rev-parse feat/7-x)"; cp "$FG/comments" "$T/before"; code="$(run 7 --refresh)"
want "$code" 0 "--refresh on an unapproved head → exit 0"
assert_contains "$(cat "$T/out")" "is not approved; not refreshing"
[ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "unapproved refresh: nothing pushed" || fail "pushed"
[ "$(cat "$FG/status")" = Staged ] && pass "unapproved refresh: card stays Staged" || fail "status $(cat "$FG/status")"
untouched "$T/before"

# --refresh when back_to_coding happens (a migration conflicts with main): exit 0, left for the deploy, nothing moves
setup; echo Staged > "$FG/status"; on_branch "$M/V2__card.sql" card; main_commit "$M/V2__card.sql" main
before="$(git --git-dir="$remote" rev-parse feat/7-x)"; cp "$FG/comments" "$T/before"; code="$(run 7 --refresh)"
want "$code" 0 "--refresh meeting back_to_coding → exit 0"
assert_contains "$(cat "$T/out")" "a migration conflicts with main"
assert_contains "$(cat "$T/out")" "left for the deploy"
[ "$(cat "$FG/status")" = Staged ] && pass "refresh back_to_coding: card stays Staged" || fail "status $(cat "$FG/status")"
[ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "refresh back_to_coding: nothing pushed" || fail "pushed"
untouched "$T/before"
posted "pr merge" && fail "refresh merged" || pass "refresh back_to_coding: no merge"

# --refresh with more than one open PR → exit 0, quietly
setup; echo Staged > "$FG/status"; printf '79\tfeat/7-y\tfalse\t%s\n' "$STAGED" > "$FG/extra-pr"
gh_with 'case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@"; cat "$FG/extra-pr"; exit 0 ;; esac'
cp "$FG/comments" "$T/before"; code="$(run 7 --refresh)"
want "$code" 0 "--refresh with two open PRs → exit 0"
untouched "$T/before"

# a fork PR → blocked, with the reason on the card
setup; gh_with 'case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@" | awk -F"\t" -v OFS="\t" "{ \$3 = \"true\"; print }"; exit 0 ;; esac'
code="$(run 7)"
want "$code" 5 "fork PR → blocked"
assert_contains "$(cat "$FG/comments")" "Factory deploy stopped: PR #78 comes from a fork; the factory deploys only its own branches"
assert_contains "$(cat "$FG/labels")" blocked
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "fork: card not moved" || fail "status $(cat "$FG/status")"
posted "pr merge" && fail "merged a fork PR" || pass "fork: nothing merged"

# more than one open PR for the card → blocked; revert/<n> beside feat/<n>-* counts too
setup; printf '79\tfeat/7-y\tfalse\t%s\n' "$STAGED" > "$FG/extra-pr"
gh_with 'case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@"; cat "$FG/extra-pr"; exit 0 ;; esac'
code="$(run 7)"
want "$code" 5 "two feat/7-* PRs → blocked"
assert_contains "$(cat "$FG/comments")" "Factory deploy stopped: expected one open PR for #7, found: 78"
assert_contains "$(cat "$FG/comments")" "79"
assert_contains "$(cat "$FG/labels")" blocked
posted "pr merge" && fail "merged with two PRs" || pass "two PRs: nothing merged"
setup; printf '80\trevert/7\tfalse\t%s\n' "$STAGED" > "$FG/extra-pr"
gh_with 'case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@"; cat "$FG/extra-pr"; exit 0 ;; esac'
code="$(run 7)"
want "$code" 5 "revert/7 beside feat/7-x → blocked"
assert_contains "$(cat "$FG/comments")" "expected one open PR for #7, found: 78"
assert_contains "$(cat "$FG/comments")" "revert/7"
assert_contains "$(cat "$FG/labels")" blocked
posted "pr merge" && fail "merged with revert beside feat" || pass "revert beside feat: nothing merged"
# the PR of another card (feat/70-z, revert/70) is not this card's
setup; printf '81\tfeat/70-z\tfalse\t%s\n82\trevert/70\tfalse\t%s\n' "$STAGED" "$STAGED" > "$FG/extra-pr"
gh_with 'case "$*" in "pr list"*"--state open"*) bash "$FAKE_GH" "$@"; cat "$FG/extra-pr"; exit 0 ;; esac'
code="$(run 7)"
want "$code" 0 "PRs of card #70 are ignored for #7"
[ "$(cat "$FG/status")" = Done ] && pass "other cards' PRs: card in Done" || fail "status $(cat "$FG/status")"

# a merged PR that is not on origin/main (never landed) → not resumed: blocked; nothing asked of production
setup; echo "$STAGED" > "$FG/merged"
code="$(run 7)"
want "$code" 5 "merged PR missing from origin/main → blocked, not RESUMED"
assert_contains "$(cat "$FG/comments")" "expected one open PR for #7, found: none"
assert_contains "$(cat "$FG/labels")" blocked
case "$(cat "$T/out")" in *"already merged as"*) fail "resumed a PR that is not on main" ;; *) pass "not resumed" ;; esac
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "missing merge: card not moved" || fail "status $(cat "$FG/status")"
# a merged PR whose merge commit is not a sha is no better
setup; echo notasha > "$FG/merged"; code="$(run 7)"
want "$code" 5 "merged PR with no merge sha → blocked"
assert_contains "$(cat "$FG/comments")" "found: none"

# RESUMED: the merged PR is on origin/main → straight to production, the PR is not merged again
setup; run 7 >/dev/null; echo "Ready for Prod" > "$FG/status"; : > "$FG/calls"; cp "$FG/comments" "$T/before"
code="$(run 7)"
want "$code" 0 "merged PR on origin/main → RESUMED, exit 0"
assert_contains "$(cat "$T/out")" "was already merged as $(cat "$FG/merged"); checking production"
[ "$(cat "$FG/status")" = Done ] && pass "resumed: card in Done" || fail "status $(cat "$FG/status")"
posted "pr merge" && fail "merged twice" || pass "resumed: no second merge"
assert_contains "$(cat "$FG/comments")" "Deployed: merge $(cat "$FG/merged")"
finish
