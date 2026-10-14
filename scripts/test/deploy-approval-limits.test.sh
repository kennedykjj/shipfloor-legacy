#!/usr/bin/env bash
# deploy.sh approval at its edges: the 10-step approved_chain, a second parent not on main, CRLF in comments,
# a login that would break the jq splice of ME. Each case checks the exit code and what the fake gh recorded.
source "$(dirname "$0")/deploy-lib.sh"
export FAKE_GH="$FACTORY_DIR/test/fake-gh-deploy"
gh_with() {  # gh_with '<shell>': the fake gh behind a snippet that may answer a call itself (L logs it) or let it through
  printf '#!/usr/bin/env bash\nL() { echo "$*" >> "$FG/calls"; }\n%s\nexec bash "%s" "$@"\n' "$1" "$FAKE_GH" > "$T/gh"
  chmod +x "$T/gh"; export FACTORY_GH="$T/gh"
}
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out")"; }
posted() { case "$(cat "$FG/calls" 2>/dev/null)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
card_clone() { w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t; }
chain() {  # chain <k> [<line ending>]: k commits on the card's branch, each recorded by the factory as a deploy-fix
  local i; card_clone
  for i in $(seq 1 "$1"); do
    echo "$i" > "$w/api/F$i.kt"; git -C "$w" add -A; git -C "$w" commit -qm "fix $i"
    printf 'factory\tdeploy-fix: %s%s\n' "$(git -C "$w" rev-parse HEAD)" "${2:-}" >> "$FG/comments"
  done
  git -C "$w" push -q origin feat/7-x
}
done_ok() {  # the card shipped: exit 0, in Done, the Deployed comment
  want "$code" 0 "$1 → exit 0"
  [ "$(cat "$FG/status")" = Done ] && pass "$1: card in Done" || fail "status $(cat "$FG/status")"
  assert_contains "$(cat "$FG/comments")" "Deployed: merge"
}
unapproved() {  # the card was blocked as changed after staging, and nothing merged
  want "$code" 5 "$1 → blocked"
  assert_contains "$(cat "$FG/comments")" "Factory deploy stopped: PR #78 changed after it was staged"
  assert_contains "$(cat "$FG/labels")" blocked
  [ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "$1: card not moved" || fail "status $(cat "$FG/status")"
  posted "pr merge" && fail "$1: merged" || pass "$1: nothing merged"
}

# AC-2: a chain of 9 recorded commits above the approved head is within approved_chain's 10 steps...
setup; chain 9; code="$(run 7)"; done_ok "9 recorded fixes above the staged head"
# ...10 are one too many
setup; chain 10; code="$(run 7)"; unapproved "10 recorded fixes above the staged head"
# a commit nobody recorded in the middle of the chain breaks it
setup; card_clone; echo a > "$w/api/G1.kt"; git -C "$w" add -A; git -C "$w" commit -qm g1
printf 'factory\tdeploy-fix: %s\n' "$(git -C "$w" rev-parse HEAD)" >> "$FG/comments"
echo b > "$w/api/G2.kt"; git -C "$w" add -A; git -C "$w" commit -qm g2; git -C "$w" push -q origin feat/7-x
code="$(run 7)"; unapproved "an unrecorded head on a recorded chain"
# a record under an older staged-head is not counted once a newer staged-head replaced it
setup; card_clone; echo a > "$w/api/G1.kt"; git -C "$w" add -A; git -C "$w" commit -qm g1; rec="$(git -C "$w" rev-parse HEAD)"
git -C "$w" push -q origin feat/7-x
printf 'factory\tdeploy-fix: %s\nfactory\tstaged-head: 1111111111111111111111111111111111111111\n' "$rec" >> "$FG/comments"
code="$(run 7)"; unapproved "a record from before the newest staged-head"

# a merge whose second parent is not on main → the chain breaks; one whose second parent is on main is fine
setup; card_clone; git -C "$w" checkout -q -b side; echo s > "$w/side.txt"; git -C "$w" add -A; git -C "$w" commit -qm side
side="$(git -C "$w" rev-parse HEAD)"; git -C "$w" checkout -q feat/7-x; git -C "$w" merge -q --no-ff --no-edit side
printf 'factory\tdeploy-merge: %s %s\n' "$(git -C "$w" rev-parse HEAD)" "$side" >> "$FG/comments"; git -C "$w" push -q origin feat/7-x
code="$(run 7)"; unapproved "a recorded merge with a second parent that is not on main"
setup; main_commit web/other.ts x; card_clone; git -C "$w" merge -q --no-ff --no-edit origin/main
printf 'factory\tdeploy-merge: %s %s\n' "$(git -C "$w" rev-parse HEAD)" "$(git -C "$w" rev-parse origin/main)" >> "$FG/comments"; git -C "$w" push -q origin feat/7-x
code="$(run 7)"; done_ok "a recorded merge of main"

# CRLF in the comments: the staged-head and the records are read without the carriage return
setup; printf 'factory\tstaged-head: %s\r\n' "$STAGED" > "$FG/comments"; code="$(run 7)"; done_ok "CRLF after the staged-head"
setup; printf 'factory\tstaged-head: %s\r\n' "$STAGED" > "$FG/comments"; chain 2 $'\r'; code="$(run 7)"; done_ok "CRLF after the records"

# the login of ME is spliced into the jq filter: a login that is odd but valid works...
setup; printf 'ci-bot[bot]\tstaged-head: %s\n' "$STAGED" > "$FG/comments"
gh_with 'case "$*" in "api user"*) L "$*"; echo "ci-bot[bot]"; exit 0 ;; esac'
code="$(run 7)"; done_ok "login ci-bot[bot]"
# ...only that login's comments approve
setup; gh_with 'case "$*" in "api user"*) L "$*"; echo "someone-else"; exit 0 ;; esac'
code="$(run 7)"; want "$code" 5 "comments of another login do not approve"
assert_contains "$(cat "$FG/comments")" "no staged-head comment on #7"
assert_contains "$(cat "$FG/labels")" blocked
posted "pr merge" && fail "merged on another login's approval" || pass "another login: nothing merged"
# ...and a login with a quote breaks the filter: gh fails to read the comments, the run retries later and says nothing
setup; cp "$FG/comments" "$T/before"
gh_with 'case "$*" in "api user"*) L "$*"; echo "fa\"ctory"; exit 0 ;; "issue view"*) L "$*"; echo "jq: error: syntax error" >&2; exit 3 ;; esac'
code="$(run 7)"; want "$code" 2 "login with a quote → retry later"
assert_contains "$(cat "$T/out")" "cannot read #7 comments; will retry"
cmp -s "$T/before" "$FG/comments" && pass "broken login: no comment posted" || fail "comments changed: $(cat "$FG/comments")"
[ ! -e "$FG/labels" ] && pass "broken login: no label" || fail "labelled"
posted "pr merge" && fail "merged with a broken login" || pass "broken login: nothing merged"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "broken login: card not moved" || fail "status $(cat "$FG/status")"
finish
