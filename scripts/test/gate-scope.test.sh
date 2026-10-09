#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
mkdir -p api/src/main api/src/test web/e2e docs/superpowers/specs
echo x > api/src/main/A.kt
assert_exit 0 bash "$GATE" scope api "$base"
assert_exit 1 bash "$GATE" scope web "$base"
assert_exit 1 bash "$GATE" scope qa "$base"

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
mkdir -p api/src/test web/e2e web/lib
echo x > api/src/test/ATest.kt; echo x > web/e2e/a.spec.ts; echo x > web/lib/a.test.ts
assert_exit 0 bash "$GATE" scope qa "$base"
echo x > web/lib/a.ts
assert_exit 1 bash "$GATE" scope qa "$base"

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
mkdir -p "docs/superpowers/specs"; echo x > "docs/superpowers/specs/my spec.md"
assert_exit 0 bash "$GATE" scope po "$base"

# rename counts both paths
r="$(new_repo)"; cd "$r"; mkdir -p api .github; echo x > .github/ci.yml; git add -A; git commit -qm c; base="$(git rev-parse HEAD)"
git mv .github/ci.yml api/ci.yml
assert_exit 1 bash "$GATE" scope api "$base"

# forbidden areas
for f in .github/w.yml .githooks/pre-push .claude/x.md .aghanim/factory.yml api/.env web/.env.local; do
  r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
  mkdir -p "$(dirname "$f")"; echo x > "$f"
  assert_exit 1 bash "$GATE" forbidden "$base"
done
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p api; echo x > api/env.kt
assert_exit 0 bash "$GATE" forbidden "$base"

finish
