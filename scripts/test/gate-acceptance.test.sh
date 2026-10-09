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
finish
