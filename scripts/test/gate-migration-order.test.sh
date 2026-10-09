#!/usr/bin/env bash
# Parallel cards must not ship two migrations with one version, nor a migration older than main's.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
M=api/src/main/resources/db/migration
spec() { printf '# S\n\n## Rollback\n\nnão se aplica\n' > spec.md; }

# main already has V27 (another card merged first); this card also adds a V27 → blocked
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo 'create table a (id int);' > "$M/V26__a.sql"; git add -A; git commit -qm v26
base="$(git rev-parse HEAD)"; spec
echo 'create table b (id int);' > "$M/V27__access_log.sql"; git add -A; git commit -qm "main: V27"
echo 'create table c (id int);' > "$M/V27__retention.sql"
assert_exit 1 bash "$GATE" migration "$(git rev-parse HEAD)" spec.md
out="$(bash "$GATE" migration "$(git rev-parse HEAD)" spec.md 2>&1)"; assert_contains "$out" "V27"

# the card's migration must be newer than every migration already on its base
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; echo x > "$M/V28__b.sql"; git add -A; git commit -qm base
base="$(git rev-parse HEAD)"; spec
echo 'create table c (id int);' > "$M/V27__late.sql"
assert_exit 1 bash "$GATE" migration "$base" spec.md
rm "$M/V27__late.sql"; echo 'create table c (id int);' > "$M/V29__next.sql"
assert_exit 0 bash "$GATE" migration "$base" spec.md

# after merging main, the merge-base makes main's migrations "existing", not the card's
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; git add -A; git commit -qm v26
git checkout -qb card; echo 'create table r (id int);' > "$M/V28__retention.sql"; git add -A; git commit -qm card
git checkout -q main; echo 'create table l (id int);' > "$M/V27__log.sql"; git add -A; git commit -qm main
git checkout -q card; git merge -q --no-edit main; spec
assert_exit 0 bash "$GATE" migration "$(git merge-base HEAD main)" spec.md

# a migration whose name has no version is refused, not skipped
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; base="$(git rev-parse HEAD)"; spec
echo x > "$M/Vlatest__oops.sql"
assert_exit 1 bash "$GATE" migration "$base" spec.md

# the version pattern is configurable (golang-migrate style)
export FACTORY_CONFIG="$(mktemp)"; cat > "$FACTORY_CONFIG" <<'EOF'
project: {name: x, repo: a/x}
board: {owner: a, number: 1}
layers:
  - {name: db, path: db/, test: t, ran: ok, tests: ['db/**/*_test.go'], migrations: {glob: 'db/migrations/*.sql', version: '^([0-9]+)_'}}
EOF
r="$(new_repo)"; cd "$r"; mkdir -p db/migrations; echo x > db/migrations/000027_a.up.sql; git add -A; git commit -qm m; base="$(git rev-parse HEAD)"; spec
echo 'create table z (id int);' > db/migrations/000027_b.up.sql
assert_exit 1 bash "$GATE" migration "$base" spec.md
mv db/migrations/000027_b.up.sql db/migrations/000028_b.up.sql
assert_exit 0 bash "$GATE" migration "$base" spec.md
# up/down pairs and undo files are one migration, not a duplicate version
r="$(new_repo)"; cd "$r"; mkdir -p db/migrations; echo x > db/migrations/000027_a.up.sql; echo x > db/migrations/000027_a.down.sql; git add -A; git commit -qm m
base="$(git rev-parse HEAD)"; spec; echo x > db/migrations/000028_b.up.sql; echo x > db/migrations/000028_b.down.sql
assert_exit 0 bash "$GATE" migration "$base" spec.md
unset FACTORY_CONFIG; export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; git add -A; git commit -qm m; base="$(git rev-parse HEAD)"; spec
echo x > "$M/V27__b.sql"; echo x > "$M/U27__b.sql"
assert_exit 0 bash "$GATE" migration "$base" spec.md

# a bad name already on main does not stall cards that add no migration
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; echo x > "$M/Vlatest__x.sql"; echo x > "$M/V26__dup.sql"; git add -A; git commit -qm m
base="$(git rev-parse HEAD)"; spec; mkdir -p web; echo x > web/a.ts
assert_exit 0 bash "$GATE" migration "$base" spec.md
echo x > "$M/V27__new.sql"
assert_exit 0 bash "$GATE" migration "$base" spec.md   # the card's own migration is fine

# main took the version while the card was being built: caught before merging main
remote="$(mktemp -d)"; git init -q --bare "$remote"
r="$(new_repo)"; cd "$r"; git remote add origin "$remote"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; git add -A; git commit -qm m; git push -q origin main
git checkout -qb card; base="$(git rev-parse HEAD)"; spec; echo x > "$M/V27__card.sql"
other="$(mktemp -d)"; git clone -q "$remote" "$other"; git -C "$other" config user.email t@t; git -C "$other" config user.name t
echo x > "$other/$M/V27__main.sql"; git -C "$other" add -A; git -C "$other" commit -qm main; git -C "$other" push -q origin main
git fetch -q origin
assert_exit 1 bash "$GATE" migration "$base" spec.md
mv "$M/V27__card.sql" "$M/V28__card.sql"
assert_exit 0 bash "$GATE" migration "$base" spec.md

# a base that is not an ancestor of HEAD is a usage error, never a pass
git checkout -q main; side="$(git rev-parse HEAD)"; git checkout -q card; git commit -qm x --allow-empty
git checkout -q --orphan lone; git commit -qm lone --allow-empty; lone="$(git rev-parse HEAD)"; git checkout -q card
assert_exit 2 bash "$GATE" migration "$lone" spec.md
finish
