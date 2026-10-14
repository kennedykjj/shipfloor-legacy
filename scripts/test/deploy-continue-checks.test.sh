#!/usr/bin/env bash
# deploy.sh --continue: what check_resolution and check_fix reject or accept. Exit code and what the fake gh,
# the board and the remote recorded.
source "$(dirname "$0")/deploy-lib.sh"
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out")"; }
posted() { case "$(cat "$FG/calls" 2>/dev/null)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
scene_gatered() { on_branch docs/engineering/a.md x; main_commit web/other.ts x; code="$(run 7)"; }  # a gate fails after merging main: a fix round
wg() { git -C "$FACTORY_WT_ROOT/7" -c user.email=t@t -c user.name=t "$@"; }
resolve() { echo resolved > "$FACTORY_WT_ROOT/7/shared.txt"; wg add shared.txt; wg commit -q --no-edit; }
blocked() {  # blocked <label> <reason>: exit 5, the reason on the card, labelled, nothing pushed or merged, the card where it was
  want "$code" 5 "$1 → blocked"
  assert_contains "$(cat "$FG/comments")" "Factory deploy stopped: $2"
  assert_contains "$(cat "$FG/labels")" blocked
  [ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "$1: card not moved" || fail "status $(cat "$FG/status")"
  [ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "$1: nothing pushed" || fail "pushed"
  posted "pr merge" && fail "$1: merged" || pass "$1: nothing merged"
}
coding() {  # coding <label> <reason>: exit 4, in Coding with the reason, nothing pushed or merged
  want "$code" 4 "$1 → back to Coding"
  [ "$(cat "$FG/status")" = Coding ] && pass "$1: card in Coding" || fail "status $(cat "$FG/status")"
  assert_contains "$(cat "$FG/comments")" "Back to Coding: $2"
  [ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "$1: nothing pushed" || fail "pushed"
  posted "pr merge" && fail "$1: merged" || pass "$1: nothing merged"
}

# AC-4, check_resolution: MERGE_HEAD still there (the merge was never committed)
scene conflict; before="$(git --git-dir="$remote" rev-parse feat/7-x)"
code="$(run 7 --continue)"; blocked "--continue with MERGE_HEAD" "--continue with the merge still in progress"
# no MERGE_HEAD but the index still holds conflicts
scene conflict; before="$(git --git-dir="$remote" rev-parse feat/7-x)"
rm -f "$(git -C "$FACTORY_WT_ROOT/7" rev-parse --absolute-git-dir)/MERGE_HEAD"
code="$(run 7 --continue)"; blocked "--continue with unresolved files" "--continue with unresolved conflicts"
# resolve.parents gone: deploy.sh did not hand this conflict over
scene conflict; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; resolve; rm -f "$FACTORY_HOME/tmp/7/resolve.parents"
code="$(run 7 --continue)"; blocked "--continue without resolve.parents" "--continue without a conflict handed over by deploy.sh"
# resolve.parents naming other parents than the merge has
scene conflict; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; resolve
{ read -r a; read -r b; } < "$FACTORY_HOME/tmp/7/resolve.parents"; printf '%s\n%s\n' "$b" "$a" > "$FACTORY_HOME/tmp/7/resolve.parents"
code="$(run 7 --continue)"; blocked "--continue with the wrong parents" "--continue: HEAD is not the merge of $b and $a"
# the PR head moved after the conflicts were handed over (a new approved head)
scene conflict; resolve; on_branch api/Z.kt z; before="$(git --git-dir="$remote" rev-parse feat/7-x)"
code="$(run 7 --continue)"; blocked "--continue after the head moved" "--continue: the PR head moved since the conflicts were handed over"
# the happy path of the same scene still deploys, and clears what it handed over
scene conflict; resolve; code="$(run 7 --continue)"
want "$code" 0 "--continue with a clean resolution → deployed"
[ ! -e "$FACTORY_HOME/tmp/7/resolve.parents" ] && [ ! -e "$FACTORY_HOME/tmp/7/resolve.files" ] && pass "hand-over files cleared" || fail "hand-over files left"
[ "$(cat "$FG/status")" = Done ] && pass "resolved conflict: card in Done" || fail "status $(cat "$FG/status")"

# check_fix: a dirty worktree (untracked, then modified) → Coding
red_round; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; fix api/A.kt 3; echo junk > "$FACTORY_WT_ROOT/7/dirty.txt"; echo "api=SUCCESS" > "$FG/ci"
code="$(run 7 --continue)"; coding "fix round with an untracked file" "the fix round left uncommitted changes"
red_round; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; fix api/A.kt 3; echo junk >> "$FACTORY_WT_ROOT/7/api/A.kt"; echo "api=SUCCESS" > "$FG/ci"
code="$(run 7 --continue)"; coding "fix round with a modified file" "the fix round left uncommitted changes"
# a merge commit inside the fix range → "fixed nothing"
red_round; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; echo "api=SUCCESS" > "$FG/ci"
wg checkout -q -b side; echo s > "$FACTORY_WT_ROOT/7/side.txt"; wg add -A; wg commit -qm side; wg checkout -q feat/7-x
echo f > "$FACTORY_WT_ROOT/7/api/F.kt"; wg add -A; wg commit -qm f; wg merge -q --no-ff --no-edit side
code="$(run 7 --continue)"; coding "fix round with a merge commit" "the fix round fixed nothing"
# a large fix whose fast gates fail (it touches a forbidden path) → Coding, nothing pushed
red_round; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; fix docs/engineering/x.md 200; echo "api=SUCCESS" > "$FG/ci"
code="$(run 7 --continue)"; coding "large fix failing the fast gates" "gates failed after the fix: "
[ ! -e "$FACTORY_HOME/tmp/7/fix.parent" ] && pass "large fix: fix.parent consumed" || fail "fix.parent left"
# the thresholds: 40 lines in a new file still ship; 41 wait in Staged for the owner; so do 4 files
red_round; fix api/N.kt 40; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
want "$code" 0 "a 40-line fix ships (fix_max_lines=40)"
[ "$(cat "$FG/status")" = Done ] && pass "40-line fix: card in Done" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "deploy-fix: "
red_round; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; fix api/N.kt 41; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
want "$code" 4 "a 41-line fix → back to Staged"
[ "$(cat "$FG/status")" = Staged ] && pass "41-line fix: card in Staged" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "Back to Staged: "
posted "pr merge" && fail "merged an unapproved fix" || pass "41-line fix: nothing merged"
red_round; before="$(git --git-dir="$remote" rev-parse feat/7-x)"
for i in 1 2 3 4; do fix "api/M$i.kt" 1; done; echo "api=SUCCESS" > "$FG/ci"; code="$(run 7 --continue)"
want "$code" 4 "a fix of 4 files → back to Staged"
[ "$(cat "$FG/status")" = Staged ] && pass "4-file fix: card in Staged" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "The fix is 4 files and 4 lines"

# a fix round that started from a gate failure after merging main (today's fix tests all start from red CI)
scene gatered
want "$code" 3 "gate failure after merging main → fix round"
assert_contains "$(cat "$T/out")" "fix round 1 of 2: gates failed after merging main: "
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "gate fix round: card stays in Ready for Prod" || fail "status $(cat "$FG/status")"
[ -s "$FACTORY_HOME/tmp/7/fix.findings" ] && [ -s "$FACTORY_HOME/tmp/7/fix.parent" ] && pass "gate fix round: findings and parent kept" || fail "no findings"
[ "$(cat "$FACTORY_HOME/tmp/7/fix.round")" = 1 ] && pass "gate fix round: round 1" || fail "round $(cat "$FACTORY_HOME/tmp/7/fix.round")"
posted "pr merge" && fail "merged on a gate failure" || pass "gate fix round: nothing merged"
# ...the agent removes the forbidden file: a small fix, gates green, shipped with the merge recorded
wg rm -q docs/engineering/a.md; wg commit -qm "fix: drop the forbidden file"; code="$(run 7 --continue)"
want "$code" 0 "gate fix round → fixed and deployed"
[ "$(cat "$FG/status")" = Done ] && pass "gate fix round: card in Done" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "
assert_contains "$(cat "$FG/comments")" "deploy-fix: "
# ...a small fix that leaves the gate red goes round again, and a second red round goes to Coding
scene gatered
fix api/N.kt 1; code="$(run 7 --continue)"
want "$code" 3 "small fix, gate still red → second fix round"
assert_contains "$(cat "$T/out")" "fix round 2 of 2: gates failed after merging main: "
before="$(git --git-dir="$remote" rev-parse feat/7-x)"; fix api/N2.kt 1; code="$(run 7 --continue)"
coding "two gate-red rounds" "gates failed after merging main: "
finish
