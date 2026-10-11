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
finish
