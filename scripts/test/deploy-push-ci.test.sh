#!/usr/bin/env bash
# deploy.sh pushing the merge of main and waiting for CI: a failed push, a card moved meanwhile, a record comment that
# fails, gates failing with nothing merged, every wait_checks case, main moving three times.
# Exit code and what the fake gh, the board and the remote recorded; FACTORY_POLL=0, no sleeps.
source "$(dirname "$0")/deploy-lib.sh"
export FAKE_GH="$FACTORY_DIR/test/fake-gh-deploy"
gh_with() {  # gh_with '<shell>': the fake gh behind a snippet that may answer a call itself (L logs it) or let it through
  printf '#!/usr/bin/env bash\nL() { echo "$*" >> "$FG/calls"; }\n%s\nexec bash "%s" "$@"\n' "$1" "$FAKE_GH" > "$T/gh"
  chmod +x "$T/gh"; export FACTORY_GH="$T/gh"
}
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out")"; }
posted() { case "$(cat "$FG/calls" 2>/dev/null)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
polls() { grep -c statusCheckRollup "$FG/calls" 2>/dev/null || true; }  # how many times the checks were asked for
dcfg() { sed -i '/^deploy:/d' "$FACTORY_CONFIG"; printf 'deploy: %s\n' "$1" >> "$FACTORY_CONFIG"; }
head_of() { git --git-dir="$remote" rev-parse feat/7-x; }
blocked() {  # blocked <label> <reason>: exit 5, the reason on the card, labelled, the card where it was, nothing merged
  want "$code" 5 "$1 → blocked"
  assert_contains "$(cat "$FG/comments")" "Factory deploy stopped: $2"
  assert_contains "$(cat "$FG/labels")" blocked
  [ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "$1: card not moved" || fail "status $(cat "$FG/status")"
  posted "pr merge" && fail "$1: merged" || pass "$1: nothing merged"
}
shipped() { want "$code" 0 "$1 → exit 0"; [ "$(cat "$FG/status")" = Done ] && pass "$1: card in Done" || fail "status $(cat "$FG/status")"; }

# AC-5: the push fails (the remote refuses the branch) → blocked; the merge was recorded first, and nothing merged
scene behind; before="$(head_of)"
printf '#!/bin/sh\nwhile read o n r; do case "$r" in refs/heads/feat/*) echo rejected >&2; exit 1 ;; esac; done\n' > "$remote/hooks/pre-receive"; chmod +x "$remote/hooks/pre-receive"
code="$(run 7)"; blocked "failed push" "push of "
assert_contains "$(cat "$FG/comments")" "failed (the branch moved?)"
assert_contains "$(cat "$FG/comments")" "deploy-merge: "
[ "$(head_of)" = "$before" ] && pass "failed push: branch unchanged" || fail "branch moved"

# the card was moved while the deploy ran → retry later: nothing recorded, pushed or merged
scene behind; before="$(head_of)"; cp "$FG/comments" "$T/before"
printf '#!/usr/bin/env bash\ncase "$1" in status) c=$(cat "%s/bcount" 2>/dev/null || echo 0); echo $((c+1)) > "%s/bcount"; if [ "$c" = 0 ]; then echo "Ready for Prod"; else echo Coding; fi ;; move) echo "$3" > "%s/status" ;; esac\n' "$FG" "$FG" "$FG" > "$T/board"
code="$(run 7)"; want "$code" 2 "card moved during the run → retry later"
assert_contains "$(cat "$T/out")" "the card moved meanwhile; will retry"
cmp -s "$T/before" "$FG/comments" && pass "card moved: no record comment" || fail "comments changed: $(cat "$FG/comments")"
[ "$(head_of)" = "$before" ] && pass "card moved: nothing pushed" || fail "pushed"
posted "pr merge" && fail "card moved: merged" || pass "card moved: nothing merged"
[ ! -e "$FG/labels" ] && pass "card moved: not labelled" || fail "labelled"

# posting the record comment fails → retry later, and nothing is pushed (an unrecorded push would wedge the card)
scene behind; before="$(head_of)"; cp "$FG/comments" "$T/before"
gh_with 'case "$*" in "issue comment"*) L "$*"; echo boom >&2; exit 1 ;; esac'
code="$(run 7)"; want "$code" 2 "record comment fails → retry later"
assert_contains "$(cat "$T/out")" "cannot record the merge; will retry"
cmp -s "$T/before" "$FG/comments" && pass "failed record: no comment kept" || fail "comments changed"
[ "$(head_of)" = "$before" ] && pass "failed record: nothing pushed" || fail "pushed an unrecorded merge"
posted "pr merge" && fail "failed record: merged" || pass "failed record: nothing merged"

# the fast gates fail with nothing merged (main did not move) → blocked for the owner
setup; on_branch docs/engineering/a.md x; before="$(head_of)"; code="$(run 7)"
blocked "gates failing with nothing merged" "gates failed: "
[ "$(head_of)" = "$before" ] && pass "gates failing: nothing pushed" || fail "pushed"
[ ! -e "$FACTORY_HOME/tmp/7/fix.parent" ] && pass "gates failing: no fix round" || fail "fix round started"

# wait_checks: allow_no_checks takes 10 empty polls to give way; 9 are not enough
setup; dcfg '{allow_no_checks: true}'; : > "$FG/ci"; code="$(run 7)"
shipped "allow_no_checks with empty checks"
assert_contains "$(cat "$T/out")" "no checks reported for"
[ "$(polls)" = 10 ] && pass "allow_no_checks: 10 polls" || fail "polls $(polls)"
setup; dcfg '{allow_no_checks: true}'; : > "$FG/ci"; code="$(FACTORY_POLLS=9 run 7)"
blocked "allow_no_checks with 9 empty polls" "CI failed on the PR ("
[ "$(polls)" = 9 ] && pass "9 polls, no more" || fail "polls $(polls)"
assert_contains "$(cat "$T/out")" "checks did not finish (last: none)"
# without allow_no_checks empty checks never pass
setup; : > "$FG/ci"; code="$(FACTORY_POLLS=12 run 7)"
blocked "empty checks, allow_no_checks off" "CI failed on the PR ("
[ "$(polls)" = 12 ] && pass "empty checks: waited every poll" || fail "polls $(polls)"

# wait_checks: each failure keyword is red on the approved head → blocked at the first poll
for k in FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE STALE error; do
  setup; echo "api=SUCCESS,web=$k" > "$FG/ci"; code="$(run 7)"
  blocked "check $k" "CI failed on the PR ("
  [ "$(polls)" = 1 ] && pass "$k: red at the first poll" || fail "$k: polls $(polls)"
  assert_contains "$(cat "$T/out")" "checks failed on "
done
# NEUTRAL and SKIPPED count as green; PENDING and IN_PROGRESS do not
setup; echo "api=SUCCESS,web=NEUTRAL,e2e=SKIPPED" > "$FG/ci"; code="$(run 7)"; shipped "NEUTRAL and SKIPPED checks"
setup; echo "api=SUCCESS,web=IN_PROGRESS" > "$FG/ci"; code="$(FACTORY_POLLS=4 run 7)"
blocked "a check still in progress" "CI failed on the PR ("

# wait_checks: green needs two polls
setup; code="$(run 7)"; shipped "green checks"
[ "$(polls)" = 2 ] && pass "green needs exactly two polls" || fail "polls $(polls)"
# ...not necessarily in a row; pending polls do not count
setup; gh_with 'case "$*" in *statusCheckRollup*) c=$(cat "$FG/polls" 2>/dev/null || echo 0); echo $((c+1)) > "$FG/polls"
  if [ "$c" = 1 ]; then out="$(bash "$FAKE_GH" "$@")"; echo "${out%% *} api=IN_PROGRESS"; exit 0; fi ;; esac'
code="$(run 7)"; shipped "green, pending, green"
[ "$(polls)" = 3 ] && pass "green, pending, green: 3 polls" || fail "polls $(polls)"
setup; gh_with 'case "$*" in *statusCheckRollup*) c=$(cat "$FG/polls" 2>/dev/null || echo 0); echo $((c+1)) > "$FG/polls"
  if [ "$c" -lt 3 ]; then out="$(bash "$FAKE_GH" "$@")"; echo "${out%% *} api=IN_PROGRESS"; exit 0; fi ;; esac'
code="$(run 7)"; shipped "3 pending polls, then green"
[ "$(polls)" = 5 ] && pass "3 pending + 2 green: 5 polls" || fail "polls $(polls)"

# wait_checks: only polls on the right head count (another head's answer, green or red, is ignored)
setup; gh_with 'case "$*" in *statusCheckRollup*) c=$(cat "$FG/polls" 2>/dev/null || echo 0); echo $((c+1)) > "$FG/polls"
  bogus=0000000000000000000000000000000000000000
  if [ "$c" = 0 ]; then L "$*"; echo "$bogus api=FAILURE"; exit 0; fi
  if [ "$c" -lt 3 ]; then L "$*"; echo "$bogus api=SUCCESS"; exit 0; fi ;; esac'
code="$(run 7)"; shipped "polls on another head first"
[ "$(polls)" = 5 ] && pass "3 polls on another head + 2 on the right one" || fail "polls $(polls)"
case "$(cat "$T/out")" in *"checks failed on"*) fail "a red poll on another head counted" ;; *) pass "a red poll on another head is ignored" ;; esac
setup; gh_with 'case "$*" in *statusCheckRollup*) L "$*"; echo "0000000000000000000000000000000000000000 api=SUCCESS"; exit 0 ;; esac'
code="$(FACTORY_POLLS=4 run 7)"; blocked "checks only ever on another head" "CI failed on the PR ("
assert_contains "$(cat "$T/out")" "checks did not finish"
[ "$(polls)" = 4 ] && pass "waited every poll" || fail "polls $(polls)"

# wait_checks: timeout after merging main → Coding (the merge was recorded and pushed; nothing merged on GitHub)
scene behind; echo "api=PENDING" > "$FG/ci"; code="$(FACTORY_POLLS=3 run 7)"
want "$code" 4 "CI timeout after merging main → Coding"
[ "$(cat "$FG/status")" = Coding ] && pass "timeout: card in Coding" || fail "status $(cat "$FG/status")"
assert_contains "$(cat "$FG/comments")" "Back to Coding: CI did not finish on the PR after merging main ("
assert_contains "$(cat "$FG/comments")" "deploy-merge: "
posted "pr merge" && fail "timeout: merged" || pass "timeout: nothing merged"
[ ! -e "$FACTORY_HOME/tmp/7/fix.parent" ] && pass "timeout: no fix round" || fail "fix round started"

# red GitHub checks on the approved head, nothing merged in → blocked, not a fix round
setup; echo "api=FAILURE" > "$FG/ci"; code="$(run 7)"; blocked "red checks on the approved head" "CI failed on the PR ("
[ ! -e "$FACTORY_HOME/tmp/7/fix.parent" ] && pass "red approved head: no fix round" || fail "fix round started"

# main moves while CI runs: once → updated again and shipped; three times in a row → blocked
move_main() {  # move_main <n>: every poll of the checks lands a commit on main, up to <n> commits
  echo "$1" > "$FG/move-max"
  gh_with 'case "$*" in *statusCheckRollup*) c=$(cat "$FG/moves" 2>/dev/null || echo 0); echo $((c+1)) > "$FG/moves"
    if [ "$c" -lt "$(cat "$FG/move-max")" ]; then
      w="$(mktemp -d)"; git clone -q "$(cat "$FG/remote")" "$w"; echo "$c" > "$w/moving-$c.txt"; git -C "$w" add -A
      git -C "$w" -c user.email=t@t -c user.name=t commit -qm "main moves $c"; git -C "$w" push -q origin HEAD:main
    fi ;; esac'
}
setup; move_main 1; code="$(run 7)"; shipped "main moving once"
assert_contains "$(cat "$T/out")" "main moved while waiting for CI; updating again"
[ "$(grep -c 'deploy-merge: ' "$FG/comments")" = 1 ] && pass "main moving once: one merge recorded" || fail "merges recorded: $(grep -c 'deploy-merge: ' "$FG/comments")"
setup; move_main 99; code="$(run 7)"; blocked "main moving three times" "main kept moving; three updates in a row"
[ "$(grep -c 'main moved while waiting for CI' "$T/out")" = 3 ] && pass "main moved after each of the three waits" || fail "$(cat "$T/out")"
[ "$(grep -c 'deploy-merge: ' "$FG/comments")" = 2 ] && pass "two merges recorded" || fail "merges recorded: $(grep -c 'deploy-merge: ' "$FG/comments")"

# AC-10: no sleeps: the whole file ran inside the deploy tests' budget
[ "$SECONDS" -le 150 ] && pass "wait cases finished in ${SECONDS}s (FACTORY_POLL=0)" || fail "took ${SECONDS}s"
finish
