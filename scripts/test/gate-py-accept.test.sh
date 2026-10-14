#!/usr/bin/env bash
# AC-6 of #165: the Python acceptance-intact applies the allow paths in today's order (unchanged, only what main
# brought, both sides kept, the owner's record, acceptance_assertions), the own: keys are byte-identical to the ones
# recorded before the port, and `shipfloor accept` and an old accepted.tsv keep working.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
FIX="$FACTORY_DIR/test/fixture/factory.yml"
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
pygate --help >/dev/null 2>&1 || { fail "AC-6 the Python gate is missing: 'sf.py gate --help' fails, so acceptance-intact has no allow paths to check"; exit 1; }
TF=api/src/test/SharedTest.kt
shared() { printf '%s\n' 'class SharedTest {' "$@" '}' > "$TF"; }

expect() {  # expect <label> <exit wanted> <gate args...>: sets ERR
  local label="$1" want="$2" got; shift 2
  pygate "$@" >/dev/null 2>"$T/err"; got=$?; ERR="$(cat "$T/err")"
  case "$ERR" in "usage: sf.py"*) fail "AC-6 $label: sf.py has no gate command"; return 1 ;; esac
  if [ "$got" = "$want" ]; then pass "AC-6 $label"; else fail "AC-6 $label: python gate exit $got, want $want: $ERR"; return 1; fi
}
has() { case "$ERR" in *"$2"*) pass "AC-6 $1" ;; *) fail "AC-6 $1: no '$2' in: $ERR" ;; esac; }

# ---- the plain cases: intact, edited, deleted
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
echo 'test' > api/src/test/ATest.kt; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
echo impl > api/Impl.kt; git add -A; git commit -qm impl
expect "intact: passes" 0 acceptance-intact "$qa"
echo weakened > api/src/test/ATest.kt
expect "an uncommitted edit blocks" 1 acceptance-intact "$qa" && has "the edited file is named" "api/src/test/ATest.kt"
has "the message opens with the English block line" "acceptance-intact: acceptance tests changed after the QA commit (beyond what merges from main brought):"
has "the message offers shipfloor accept" "acceptance-intact: the owner can review these files and record them as they stand: shipfloor accept <project> <n> <reason>"
git checkout -q -- api/src/test/ATest.kt; git rm -q api/src/test/ATest.kt
expect "a deleted file blocks" 1 acceptance-intact "$qa"
git reset -q --hard HEAD
git commit -q --allow-empty -m empty
expect "a QA commit with files passes after an empty commit" 0 acceptance-intact "$qa"
git commit -q --allow-empty -m "test(x): acceptance tests for #50"; qa_empty="$(git rev-parse HEAD)"
expect "a QA commit with no files blocks" 1 acceptance-intact "$qa_empty" && has "no files message" "acceptance-intact: QA commit $qa_empty has no files"

# ---- 1. only what main brought (a clean merge), then the card's own edit on top
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git add -A; git commit -qm shared
git checkout -q -b feat/7-x
shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}' '' '  fun acceptance7() { check() }'; git commit -qam "test(x): acceptance tests for #7"; qa7="$(git rev-parse HEAD)"
git checkout -q main
shared '  fun old1() {}' '' '  fun fromMain() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git commit -qam "main adds a test"; cmain="$(git rev-parse HEAD)"; cbase="$(git rev-parse HEAD~1)"
git checkout -q feat/7-x; git merge -q --no-edit main
expect "main's merge is not the card's edit (local main only)" 0 acceptance-intact "$qa7"
git update-ref refs/remotes/origin/main "$cmain"
expect "origin/main at the same commit gives the same answer" 0 acceptance-intact "$qa7"
git update-ref refs/remotes/origin/main "$cbase"
expect "origin/main is preferred to the local main (stale: main brought nothing)" 1 acceptance-intact "$qa7"
git update-ref -d refs/remotes/origin/main
sed -i 's/fun acceptance7() { check() }/fun acceptance7() { }/' "$TF"; git commit -qam weaken
expect "the card's own edit on top of the merge blocks" 1 acceptance-intact "$qa7" && has "SharedTest.kt is named" "SharedTest.kt"
git branch -q -m main trunk
expect "FACTORY_MAIN unset and no branch main: the merge is not recognized" 1 acceptance-intact "$qa7"
( export FACTORY_MAIN=trunk; git reset -q --hard HEAD~1; expect "FACTORY_MAIN=trunk: the local trunk is the main branch" 0 acceptance-intact "$qa7" )
git branch -q -m trunk main

# ---- 2. both sides kept (a hand-resolved merge), either order; a changed line of either side blocks
for order in qa-first main-first; do
  r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
  shared '  fun old() {}'; git add -A; git commit -qm shared
  git checkout -q -b feat/12-x; shared '  fun old() {}' '' '  fun acceptance12() { check() }'; git commit -qam "test(x): acceptance tests for #12"; qa12="$(git rev-parse HEAD)"
  git checkout -q main; shared '  fun old() {}' '' '  fun fromMain() { other() }'; git commit -qam "main appends a test"
  git checkout -q feat/12-x; git merge -q --no-edit main >/dev/null 2>&1
  if [ "$order" = qa-first ]; then shared '  fun old() {}' '' '  fun acceptance12() { check() }' '' '  fun fromMain() { other() }'
  else shared '  fun old() {}' '' '  fun fromMain() { other() }' '' '  fun acceptance12() { check() }'; fi
  git commit -qam resolved
  expect "both sides kept ($order) passes" 0 acceptance-intact "$qa12"
done
shared '  fun old() {}' '' '  fun fromMain() { other() }' '' '  fun acceptance12() { }'; git commit -qam weaken
expect "a changed line of QA's side blocks" 1 acceptance-intact "$qa12"
shared '  fun old() {}' '' '  fun fromMain() { }' '' '  fun acceptance12() { check() }'; git commit -qam "edit main's test"
expect "a changed line of main's side blocks" 1 acceptance-intact "$qa12"
shared '  fun fromMain() { other() }' '' '  fun acceptance12() { check() }'; git commit -qam "drop a test both sides had"
expect "dropping a line both sides had blocks" 1 acceptance-intact "$qa12"

# ---- 3. the owner's record: by blob, by own: key, by deletion, for another file, with FACTORY_HOME unset
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun a() { one() }'; git add -A; git commit -qm shared
git checkout -q -b feat/8-x; shared '  fun a() { qa() }'; git commit -qam "test(x): acceptance tests for #8"; qa8="$(git rev-parse HEAD)"
git checkout -q main; shared '  fun a() { main() }'; git commit -qam "main edits the same line"
git checkout -q feat/8-x; git merge -q --no-edit main >/dev/null 2>&1
shared '  fun a() { main() }'; git commit -qam resolved
expect "a hand-resolved merge with no record blocks" 1 acceptance-intact "$qa8"
printf '%s\t%s\t#8\t2026-10-10\treworded\n' "$TF" "$(git rev-parse "HEAD:$TF")" > "$FACTORY_HOME/accepted.tsv"
expect "a record by blob (written before the port) lets it through" 0 acceptance-intact "$qa8"
( unset FACTORY_HOME; expect "FACTORY_HOME unset: the record is not found, blocked (no crash)" 1 acceptance-intact "$qa8" && has "the blocked file is named" "$TF" )
printf '%s\tdeleted\t#8\t2026-10-10\tgone\n' api/src/test/Gone.kt > "$FACTORY_HOME/accepted.tsv"
expect "a record for another file does not accept this one" 1 acceptance-intact "$qa8"
shared '  fun a() { edited-later() }'; git commit -qam "edit after"
printf '%s\t%s\t#8\t2026-10-10\told content\n' "$TF" "$(git rev-parse "HEAD~1:$TF")" > "$FACTORY_HOME/accepted.tsv"
expect "a record of an older blob does not accept a later edit" 1 acceptance-intact "$qa8"
rm -f "$FACTORY_HOME/accepted.tsv"

# ---- 4. the own: key is byte-identical to what a pre-port shipfloor accept recorded
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun a() { one() }' '' '  fun m() {}' '' '  fun z() {}'; git add -A; git commit -qm shared
git checkout -q -b feat/11-x; shared '  fun a() { qa() }' '' '  fun m() {}' '' '  fun z() {}'; git commit -qam "test(x): acceptance tests for #11"; qa11="$(git rev-parse HEAD)"
shared '  fun a() { adapted() }' '' '  fun m() {}' '' '  fun z() {}'; git commit -qam "the card adapts its own test"
want="own:$(printf '%s\n' '<   fun a() { qa() }' '>   fun a() { adapted() }' | git hash-object --stdin)"
got="$(pygate acceptance-own "$qa11" "$TF" 2>"$T/err")"
case "$(cat "$T/err")" in "usage: sf.py"*) fail "AC-6 sf.py has no gate command" ;; *) [ "$got" = "$want" ] && pass "AC-6 acceptance-own is 'own:' + the hash of the own-edit lines and a trailing newline" || fail "AC-6 own key '$got', want '$want' ($(cat "$T/err"))" ;; esac
expect "without an accepted.tsv the adapted test blocks" 1 acceptance-intact "$qa11"
printf '%s\t%s\t#11\t2026-10-10\tadapted\n' "$TF" "$want" > "$FACTORY_HOME/accepted.tsv"
expect "a record by own: key (written before the port) lets it through" 0 acceptance-intact "$qa11"
git checkout -q main; shared '  fun a() { one() }' '' '  fun m() {}' '' '  fun z() {}' '' '  fun fromMain() {}'; git commit -qam "main adds a test"
git checkout -q feat/11-x; git merge -q --no-edit main
expect "a merge from main elsewhere in the file keeps the own: key valid" 0 acceptance-intact "$qa11"
got="$(pygate acceptance-own "$qa11" "$TF" 2>/dev/null)"
[ "$got" = "$want" ] && pass "AC-6 the own: key does not move with a merge from main elsewhere in the file" || fail "AC-6 own key after the merge '$got', want '$want'"
sed -i 's/adapted()/weakened()/' "$TF"; git commit -qam "edit after the owner accepted"
expect "a further edit by the card blocks again" 1 acceptance-intact "$qa11"
got="$(pygate acceptance-own "$qa11" "$TF" 2>/dev/null)"
[ -n "$got" ] && [ "$got" != "$want" ] && pass "AC-6 a different own edit has a different own: key" || fail "AC-6 key after another edit: '$got'"
got="$(pygate acceptance-own "$qa11" api/src/test/Nope.kt 2>/dev/null)"
[ -z "$got" ] && pass "AC-6 acceptance-own prints nothing for a file the card did not edit" || fail "AC-6 acceptance-own of an unedited file: '$got'"
rm -f "$FACTORY_HOME/accepted.tsv"

# ---- 5. acceptance_assertions lets an edit through when no assertion line moved
CFG="$T/assertions.yml"; { cat "$FIX"; echo "acceptance_assertions: 'assert|expect\('"; } > "$CFG"
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/10-x
shared '  fun a() {' '    val s = Service(repo)' '    assertEquals(1, s.count())' '  }'; git add -A; git commit -qm "test(x): acceptance tests for #10"; qa10="$(git rev-parse HEAD)"
shared '  fun a() {' '    val s = Service(repo, clock)' '    assertEquals(1, s.count())' '  }'; git commit -qam "adapt to the constructor main changed"
expect "without acceptance_assertions the adaptation blocks" 1 acceptance-intact "$qa10"
( export FACTORY_CONFIG="$CFG"
  expect "with acceptance_assertions an edit with no assertion line moved passes" 0 acceptance-intact "$qa10" && has "it says why it passed" "acceptance-intact: $TF changed, but no assertion line did (acceptance_assertions); passed"
  shared '  fun a() {' '    val s = Service(repo, clock)' '    assertEquals(0, s.count())' '  }'; git commit -qam "weaken the assertion"
  expect "a changed assertion blocks" 1 acceptance-intact "$qa10"
  shared '  fun a() {' '    val s = Service(repo, clock)' '  }'; git commit -qam "drop the assertion"
  expect "a dropped assertion blocks" 1 acceptance-intact "$qa10" )

# ---- 6. a file the QA commit added and the implementation deleted (a stub), and every QA commit of the card counts
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
echo 'test' > api/src/test/ATest.kt; echo 'stub' > api/src/test/RedStubs.kt; git add -A; git commit -qm qa; qa9="$(git rev-parse HEAD)"
git rm -q api/src/test/RedStubs.kt; git commit -qm "the real class replaces the stub"
expect "a deleted stub blocks" 1 acceptance-intact "$qa9" && has "the stub is named" "api/src/test/RedStubs.kt"
printf '%s\tdeleted\t#9\t2026-10-10\tstub replaced\n' api/src/test/RedStubs.kt > "$FACTORY_HOME/accepted.tsv"
expect "the owner's deletion record lets it through" 0 acceptance-intact "$qa9"
rm api/src/test/ATest.kt
expect "a file deleted but not committed is still a change" 1 acceptance-intact "$qa9"
rm -f "$FACTORY_HOME/accepted.tsv"; git checkout -q -- .
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/5-x
echo a > api/src/test/ATest.kt; echo b > api/src/test/BTest.kt; git add -A; git commit -qm "test(x): acceptance tests for #5"
echo more >> api/src/test/ATest.kt; git commit -qam "test(x): acceptance tests for #5"; qa5="$(git rev-parse HEAD)"
expect "the amendment is the baseline" 0 acceptance-intact "$qa5"
echo c > api/src/test/BTest.kt; git commit -qam "edit a file the amendment did not touch"
expect "a file only the first QA commit wrote is still protected" 1 acceptance-intact "$qa5" && has "BTest.kt is named" "api/src/test/BTest.kt"

# ---- 7. shipfloor accept end to end: it records the key the Python gate computes, and the Python gate takes it
( unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
  export SHIPFLOOR_HOME="$(mktemp -d)"
  remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.shipfloor"; cp "$FIX" "$r/.shipfloor/factory.yml"
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  bash "$FACTORY_DIR/shipfloor" add "$r" >/dev/null 2>&1
  W="$(mktemp -d)/9"; git -C "$r" worktree add -q -b feat/9-x "$W" main; mkdir -p "$W/api/src/test"
  echo qa > "$W/api/src/test/NineTest.kt"; git -C "$W" add -A; git -C "$W" commit -qm "test(x): acceptance tests for #9"; q9="$(git -C "$W" rev-parse HEAD)"
  echo resolved > "$W/api/src/test/NineTest.kt"; git -C "$W" commit -qam "merge resolved by hand"
  sed -i "s#^shop\t\([^\t]*\)\t[^\t]*#shop\t\1\t$(dirname "$W")#" "$SHIPFLOOR_HOME/registry.tsv"
  H2="$SHIPFLOOR_HOME/projects/shop"
  expect "(accept) a hand edit of the card's test blocks" 1 -C "$W" acceptance-intact "$q9"
  out="$(bash "$FACTORY_DIR/shipfloor" accept shop 9 main reworded the setup 2>&1)"
  case "$out" in *"api/src/test/NineTest.kt"*) pass "AC-6 shipfloor accept names the file it took" ;; *) fail "AC-6 shipfloor accept: $out" ;; esac
  key="$(pygate -C "$W" acceptance-own "$q9" api/src/test/NineTest.kt 2>/dev/null)"
  [ -n "$key" ] && grep -qF "api/src/test/NineTest.kt	$key	" "$H2/accepted.tsv" && pass "AC-6 accepted.tsv holds the key the Python acceptance-own prints" || fail "AC-6 accepted.tsv: $(cat "$H2/accepted.tsv" 2>/dev/null) / key '$key'"
  expect "(accept) the Python gate takes what shipfloor accept recorded" 0 -C "$W" acceptance-intact "$q9"
  echo again >> "$W/api/src/test/NineTest.kt"; git -C "$W" commit -qam "edit after the owner accepted"
  expect "(accept) a later edit blocks again" 1 -C "$W" acceptance-intact "$q9" )
finish
