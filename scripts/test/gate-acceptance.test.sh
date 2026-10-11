#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"

r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
echo 'test' > api/src/test/ATest.kt; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
echo impl > api/Impl.kt; git add -A; git commit -qm impl
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
echo 'weakened' > api/src/test/ATest.kt
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
git checkout -q -- api/src/test/ATest.kt; git rm -q api/src/test/ATest.kt
assert_exit 1 bash "$GATE" acceptance-intact "$qa"

# a test file shared with main: what a merge from main brings is not the card weakening its tests
T=api/src/test/SharedTest.kt
shared() { printf '%s\n' 'class SharedTest {' "$@" '}' > "$T"; }
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git add -A; git commit -qm shared
git checkout -q -b feat/7-x
shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}' '' '  fun acceptance7() { check() }'
git commit -qam qa; qa="$(git rev-parse HEAD)"
git checkout -q main
shared '  fun old1() {}' '' '  fun fromMain() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git commit -qam "main adds a test"
git checkout -q feat/7-x; git merge -q --no-edit main
assert_contains "$(cat "$T")" "fromMain"
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
# ...but the card's own edit on top of the merge still counts
sed -i 's/fun acceptance7() { check() }/fun acceptance7() { }/' "$T"; git commit -qam weaken
out="$(bash "$GATE" acceptance-intact "$qa" 2>&1)"; code=$?
[ "$code" = 1 ] && pass "own edit after a merge blocks" || fail "own edit after a merge: exit $code"
assert_contains "$out" "SharedTest.kt"

# a merge that needed a hand resolution in the acceptance file cannot be told apart from a weakening
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun a() { one() }'; git add -A; git commit -qm shared
git checkout -q -b feat/8-x; shared '  fun a() { qa() }'; git commit -qam qa; qa="$(git rev-parse HEAD)"
git checkout -q main; shared '  fun a() { main() }'; git commit -qam "main edits the same line"
git checkout -q feat/8-x; git merge -q --no-edit main >/dev/null 2>&1
shared '  fun a() { main() }'; git commit -qam resolved
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
# ...until the owner reviews that file and accepts it as it stands (aghanim accept): that exact content passes,
# and any later edit blocks again
printf '%s\t%s\t#8\t2026-10-10\tmain reworded the same line\n' "$T" "$(git rev-parse "HEAD:$T")" > "$FACTORY_HOME/accepted.tsv"
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
shared '  fun a() { }'; git commit -qam "edit after the owner accepted"
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
rm -f "$FACTORY_HOME/accepted.tsv"

# QA and main append tests at the same spot: git conflicts, but a resolution that keeps both hunks whole, in either order, passes
for order in qa-first main-first; do
  r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
  shared '  fun old() {}'; git add -A; git commit -qm shared
  git checkout -q -b feat/12-x; shared '  fun old() {}' '' '  fun acceptance12() { check() }'; git commit -qam qa; qa="$(git rev-parse HEAD)"
  git checkout -q main; shared '  fun old() {}' '' '  fun fromMain() { other() }'; git commit -qam "main appends a test"
  git checkout -q feat/12-x; git merge -q --no-edit main >/dev/null 2>&1
  if [ "$order" = qa-first ]; then shared '  fun old() {}' '' '  fun acceptance12() { check() }' '' '  fun fromMain() { other() }'
  else shared '  fun old() {}' '' '  fun fromMain() { other() }' '' '  fun acceptance12() { check() }'; fi
  git commit -qam resolved
  assert_exit 0 bash "$GATE" acceptance-intact "$qa"
done
# ...but not one that changes a line of either side
shared '  fun old() {}' '' '  fun fromMain() { other() }' '' '  fun acceptance12() { }'; git commit -qam weaken
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
shared '  fun old() {}' '' '  fun fromMain() { }' '' '  fun acceptance12() { check() }'; git commit -qam "edit main's test"
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
shared '  fun fromMain() { other() }' '' '  fun acceptance12() { check() }'; git commit -qam "drop a test both sides had"
assert_exit 1 bash "$GATE" acceptance-intact "$qa"

# a file the QA commit added and the implementation deleted (a stub that let the red tests compile) blocks...
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
echo 'test' > api/src/test/ATest.kt; echo 'stub' > api/src/test/RedStubs.kt; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
git rm -q api/src/test/RedStubs.kt; git commit -qm "the real class replaces the stub"
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
# ...until the owner accepts the deletion; a file deleted but not committed is still a change
printf '%s\tdeleted\t#9\t2026-10-10\tstub replaced by the real class\n' api/src/test/RedStubs.kt > "$FACTORY_HOME/accepted.tsv"
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
rm api/src/test/ATest.kt
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
rm -f "$FACTORY_HOME/accepted.tsv"

# acceptance_assertions: a project may let through edits that add or remove no assertion line (setup, fixtures, locators)
CFG="$(mktemp)"; { cat "$FACTORY_CONFIG"; echo "acceptance_assertions: 'assert|expect\('"; } > "$CFG"
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/10-x
shared '  fun a() {' '    val s = Service(repo)' '    assertEquals(1, s.count())' '  }'; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
shared '  fun a() {' '    val s = Service(repo, clock)' '    assertEquals(1, s.count())' '  }'; git commit -qam "adapt to the constructor main changed"
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
FACTORY_CONFIG="$CFG" assert_exit 0 bash "$GATE" acceptance-intact "$qa"
shared '  fun a() {' '    val s = Service(repo, clock)' '    assertEquals(0, s.count())' '  }'; git commit -qam "weaken the assertion"
FACTORY_CONFIG="$CFG" assert_exit 1 bash "$GATE" acceptance-intact "$qa"
shared '  fun a() {' '    val s = Service(repo, clock)' '  }'; git commit -qam "drop the assertion"
FACTORY_CONFIG="$CFG" assert_exit 1 bash "$GATE" acceptance-intact "$qa"

# the owner accepts the card's own edit, not the whole file: a later merge from main elsewhere in the file keeps it
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun a() { one() }' '' '  fun m() {}' '' '  fun z() {}'; git add -A; git commit -qm shared
git checkout -q -b feat/11-x; shared '  fun a() { qa() }' '' '  fun m() {}' '' '  fun z() {}'; git commit -qam qa; qa="$(git rev-parse HEAD)"
shared '  fun a() { adapted() }' '' '  fun m() {}' '' '  fun z() {}'; git commit -qam "the card adapts its own test"
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
own="$(bash "$GATE" acceptance-own "$qa" "$T")"
assert_contains "$own" "own:"
printf '%s\t%s\t#11\t2026-10-10\tadapted to the new setup\n' "$T" "$own" > "$FACTORY_HOME/accepted.tsv"
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
git checkout -q main; shared '  fun a() { one() }' '' '  fun m() {}' '' '  fun z() {}' '' '  fun fromMain() {}'; git commit -qam "main adds a test"
git checkout -q feat/11-x; git merge -q --no-edit main
assert_contains "$(cat "$T")" "fromMain"
assert_exit 0 bash "$GATE" acceptance-intact "$qa"
# ...and a further edit by the card blocks again
sed -i 's/adapted()/weakened()/' "$T"; git commit -qam "edit after the owner accepted"
assert_exit 1 bash "$GATE" acceptance-intact "$qa"
rm -f "$FACTORY_HOME/accepted.tsv"

# the QA commit of a card is found one way by every stage: the newest "acceptance tests for #<n>" on the branch
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/14-x
assert_exit 2 bash "$GATE" qa-commit
assert_exit 2 bash "$GATE" qa-commit x
echo t > api/src/test/OtherTest.kt; git add -A; git commit -qm "test(x): acceptance tests for #142"
assert_exit 1 bash "$GATE" qa-commit 14
echo t > api/src/test/ATest.kt; git add -A; git commit -qm "test(x): acceptance tests for #14"; q1="$(git rev-parse HEAD)"
[ "$(bash "$GATE" qa-commit 14)" = "$q1" ] && pass "qa-commit prints the QA commit" || fail "qa-commit: want $q1"
[ "$(bash "$GATE" qa-commit 14 --head)" = "$q1" ] && pass "qa-commit --head passes right after QA" || fail "qa-commit --head: want $q1"
echo impl > api/Impl.kt; git add -A; git commit -qm impl
[ "$(bash "$GATE" qa-commit 14)" = "$q1" ] && pass "qa-commit after the implementation" || fail "qa-commit after impl: want $q1"
assert_exit 1 bash "$GATE" qa-commit 14 --head
# a rework: QA commits again and that commit is the QA commit from then on
echo t2 > api/src/test/ATest.kt; git commit -qam "test(x): acceptance tests for #14"; q2="$(git rev-parse HEAD)"
[ "$(bash "$GATE" qa-commit 14 --head)" = "$q2" ] && pass "qa-commit takes the rework's QA commit" || fail "qa-commit rework: want $q2"
# ...and a rework committed under another message is caught at once, not by a later stage reading the old QA commit
echo t3 > api/src/test/ATest.kt; git commit -qam "test(x): one world per state for #14"
out="$(bash "$GATE" qa-commit 14 --head 2>&1)"; code=$?
[ "$code" = 1 ] && pass "a QA commit under another message blocks" || fail "QA commit under another message: exit $code"
assert_contains "$out" "acceptance tests for #14"
# language: what a gate says comes out in the project's language; the exit code and the gate's name do not change
PT="$(mktemp)"; { cat "$FACTORY_CONFIG"; echo "language: pt-BR"; } > "$PT"
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/13-x
echo 'test' > api/src/test/ATest.kt; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
echo 'weakened' > api/src/test/ATest.kt; git commit -qam weaken
out="$(FACTORY_CONFIG="$PT" bash "$GATE" acceptance-intact "$qa" 2>&1)"; code=$?
[ "$code" = 1 ] && pass "pt-BR gate still blocks" || fail "pt-BR gate: exit $code"
assert_contains "$out" "acceptance-intact: os testes de aceitação mudaram depois do commit do QA"
FACTORY_CONFIG="$PT" assert_exit 0 bash "$GATE" acceptance-intact "$(git rev-parse HEAD)"
assert_exit 1 env FACTORY_CONFIG="$(f="$(mktemp)"; { cat "$FACTORY_CONFIG"; echo "language: klingon"; } > "$f"; echo "$f")" bash "$FACTORY_DIR/aghanim-config.sh" validate
finish
