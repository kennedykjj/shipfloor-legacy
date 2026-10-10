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
finish
