#!/usr/bin/env bash
# Regression tests for the whole-branch review findings on gate.sh.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
bin="$(mktemp -d)"
fake() {  # fake <name> <exit> <output>
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$3" "$2" > "$bin/$1"; chmod +x "$bin/$1"
}

# C1: empty or invalid base fails closed
r="$(new_repo)"; cd "$r"; mkdir -p .github; echo x > .github/w.yml; git add -A; git commit -qm c
assert_exit 2 bash "$GATE" scope api ""
assert_exit 2 bash "$GATE" scope api nonexistent123
assert_exit 2 bash "$GATE" forbidden ""
assert_exit 2 bash "$GATE" migration "" spec.md
assert_exit 2 bash "$GATE" build ""
assert_exit 2 bash "$GATE" acceptance-intact ""

# C2: committed change restored on disk still counts
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p web api
echo x > web/B.ts; echo y > api/A.kt; git add -A; git commit -qm sneaky; rm web/B.ts
assert_exit 1 bash "$GATE" scope api "$base"
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
echo good > api/src/test/ATest.kt; git add -A; git commit -qm qa; qa="$(git rev-parse HEAD)"
echo weak > api/src/test/ATest.kt; git add -A; git commit -qm weaken; echo good > api/src/test/ATest.kt
assert_exit 1 bash "$GATE" acceptance-intact "$qa"

# M4: instructions and repo config are off-limits
for f in CLAUDE.md .gitattributes .mcp.json docs/engineering/review-criteria.md; do
  r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$(dirname "$f")"; echo x > "$f"
  assert_exit 1 bash "$GATE" forbidden "$base"
done

# I5: test-runner config is off-limits to implementers
for f in web/vitest.config.ts web/playwright.config.ts api/src/test/resources/junit-platform.properties; do
  r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$(dirname "$f")"; echo x > "$f"
  role=api; case "$f" in web/*) role=web ;; esac
  assert_exit 1 bash "$GATE" scope "$role" "$base"
done

# I5: green gate requires the acceptance tests to run and pass
r="$(new_repo)"; cd "$r"; mkdir -p api web
fake mvn 0 "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0"
assert_exit 0 env FACTORY_MVN="$bin/mvn" bash "$GATE" green api ATest
fake mvn 0 "Tests run: 0, Failures: 0, Errors: 0, Skipped: 0"
assert_exit 1 env FACTORY_MVN="$bin/mvn" bash "$GATE" green api ATest
fake mvn 1 "Tests run: 3, Failures: 1"
assert_exit 1 env FACTORY_MVN="$bin/mvn" bash "$GATE" green api ATest
fake pnpm 0 "Tests  4 passed (4)"
assert_exit 0 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web lib/a.test.ts
fake pnpm 0 "No test files found"
assert_exit 1 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web lib/a.test.ts
fake pnpm 0 "  2 passed (3.1s)"
assert_exit 0 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" green e2e e2e/a.spec.ts

# I4: red gate false passes
fake pnpm 1 'ERROR: Expected ";" but found "b"'
assert_exit 1 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web lib/a.test.ts
fake pnpm 1 "TypeError: x is not a function
  > 5 | expect(x()).toBe(1)"
assert_exit 1 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web lib/a.test.ts
fake pnpm 1 "Error: page.goto: net::ERR_CONNECTION_REFUSED at http://localhost:3000/
  > 9 | await expect(page.getByText('x')).toBeVisible()"
assert_exit 1 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red e2e e2e/a.spec.ts
fake mvn 1 "org.opentest4j.AssertionFailedError: expected: <429> but was: <200>
Tests run: 4, Failures: 1, Errors: 3, Skipped: 0"
assert_exit 1 env FACTORY_MVN="$bin/mvn" bash "$GATE" red api ATest
fake mvn 1 "java.lang.IllegalStateException: Failed to load ApplicationContext"
assert_exit 1 env FACTORY_MVN="$bin/mvn" bash "$GATE" red api ATest
fake pnpm 1 "AssertionError: expected 'a' to be 'b'
Expected: \"b\"
Received: \"a\""
assert_exit 0 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web lib/a.test.ts

# I6: migration gaps
M=api/src/main/resources/db/migration
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo 'CREATE TABLE a (id int);' > "$M/V1__init.sql"; git add -A; git commit -qm v1; base="$(git rev-parse HEAD)"
printf '# S\n\n## Rollback\n\nnão se aplica\n' > spec.md
echo 'CREATE TABLE a (id bigint);' > "$M/V1__init.sql"
assert_exit 1 bash "$GATE" migration "$base" spec.md
git checkout -q -- "$M/V1__init.sql"
echo 'DELETE FROM users;' > "$M/V2__d.sql"
assert_exit 1 bash "$GATE" migration "$base" spec.md
echo 'TRUNCATE users;' > "$M/V2__d.sql"
assert_exit 1 bash "$GATE" migration "$base" spec.md
printf '# S\n\n## Rollback\n\n<!-- descreva -->\n' > spec.md
assert_exit 1 bash "$GATE" migration "$base" spec.md
rm "$M/V2__d.sql"; echo 'ALTER TABLE a DROP COLUMN b;' > "$M/V3__remoção.sql"
assert_exit 1 bash "$GATE" migration "$base" spec.md
finish
