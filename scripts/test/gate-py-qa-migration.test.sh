#!/usr/bin/env bash
# AC-7 of #165: the Python qa-amend (keep regex, max+1 count, SKIP_MARKS) and migration (## Rollback rules, destructive
# keywords, version order, non-blocking warnings for main's bad names) behave as the Bash ones do.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
FIX="$FACTORY_DIR/test/fixture/factory.yml"
M=api/src/main/resources/db/migration
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
pygate --help >/dev/null 2>&1 || { fail "AC-7 the Python gate is missing: 'sf.py gate --help' fails, so qa-amend and migration cannot be checked"; exit 1; }

expect() {  # expect <label> <exit wanted> <gate args...>: sets ERR
  local label="$1" want="$2" got; shift 2
  pygate "$@" >/dev/null 2>"$T/err"; got=$?; ERR="$(cat "$T/err")"
  case "$ERR" in "usage: sf.py"*) fail "AC-7 $label: sf.py has no gate command"; return 1 ;; esac
  if [ "$got" = "$want" ]; then pass "AC-7 $label"; else fail "AC-7 $label: python gate exit $got, want $want: $ERR"; return 1; fi
}
has() { case "$ERR" in *"$2"*) pass "AC-7 $1" ;; *) fail "AC-7 $1: no '$2' in: $ERR" ;; esac; }

# ======================= qa-amend =======================
ATEST=api/src/test/ATest.kt
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/5-x
printf '%s\n' 'fun a() {' '  assertEquals(1, one())' '  assertTrue(ok())' '}' > "$ATEST"; echo 'fun b() { assertTrue(b()) }' > api/src/test/BTest.kt
git add -A; git commit -qm "test(x): acceptance tests for #5"; qa5="$(git rev-parse HEAD)"
expect "one QA commit: nothing was amended" 1 qa-amend 5 && has "says there is one QA commit" "qa-amend: #5 has one QA commit, so nothing was amended"
echo impl > api/Impl.kt; git add -A; git commit -qm "feat(api): impl"; pre="$(git rev-parse HEAD)"
expect "the last commit is not QA's" 1 qa-amend 5 && has "says the last commit is not a QA commit" "qa-amend: the last commit is not a QA commit (\"acceptance tests for #5\")"
amend() { printf '%s\n' "$@" >> "$ATEST"; git commit -qam "test(x): acceptance tests for #5"; }

# the keep regex: default assert|expect\(|verify\(|should
sed -i 's/assertEquals(1, one())/assertEquals(1, oneTrimmed())/' "$ATEST"; git commit -qam "test(x): acceptance tests for #5"
expect "an amendment that checks differently passes" 0 qa-amend 5 && has "says 1 assertion line replaced by 1" "qa-amend: ok, 1 assertion lines replaced by 1"
git reset -q --hard "$pre"
sed -i '/assertTrue(ok())/d' "$ATEST"; git commit -qam "test(x): acceptance tests for #5"
expect "an amendment that drops an assertion is refused" 1 qa-amend 5 && has "says it removes 1 and adds 0" "qa-amend: the amendment removes 1 assertion lines and adds 0; an amended test may check differently, not less"
git reset -q --hard "$pre"
amend 'verify(repo).save(x)' 'expect(a).toBe(1)' 'it should work'
expect "added lines matching verify( expect( should count as assertions" 0 qa-amend 5 && has "counts the gained lines" "qa-amend: ok, 0 assertion lines replaced by 3"
git reset -q --hard "$pre"
sed -i '/assertTrue(ok())/d' "$ATEST"; printf '%s\n' '  check(ok())' >> "$ATEST"; git commit -qam "test(x): acceptance tests for #5"
expect "an assertion swapped for a line that does not match the default regex is refused" 1 qa-amend 5
CFG="$T/keep.yml"; { cat "$FIX"; echo "acceptance_assertions: 'check\('"; } > "$CFG"
( export FACTORY_CONFIG="$CFG"
  expect "acceptance_assertions in the config is the keep regex (assert lines no longer count: passes)" 0 qa-amend 5 && has "counts with the configured regex" "qa-amend: ok, 0 assertion lines replaced by 1" )
git reset -q --hard "$pre"
amend '// plain comment'
expect "an amendment with no assertion line at all passes (0 lost, 0 gained)" 0 qa-amend 5 && has "says 0 replaced by 0" "qa-amend: ok, 0 assertion lines replaced by 0"
git reset -q --hard "$pre"
# files that are not tests
echo x >> api/Impl.kt; echo '// note' >> "$ATEST"; git commit -qam "test(x): acceptance tests for #5"
expect "an amendment that touches a file that is not a test is refused" 1 qa-amend 5 && has "names the non-test file" "qa-amend: the amendment touches files that are not tests:"
has "lists api/Impl.kt" "api/Impl.kt"
git reset -q --hard "$pre"

# SKIP_MARKS
for mark in 'describe.only("a", fn)' 'it.skip("a", fn)' 'test.fixme("a", fn)' 'it.todo("a")' '@Ignore' '@Disabled' 'xit("a") {}' 'xdescribe("a") {}' 'xtest("a") {}' 't.Skip("later")' '@pytest.mark.skip'; do
  amend "$mark"
  expect "an amendment that adds '$mark' is refused" 1 qa-amend 5 && has "names '$mark' as switched off" "qa-amend: the amendment switches a test off:"
  case "$ERR" in *"$mark"*) pass "AC-7 '$mark' is listed" ;; *) fail "AC-7 '$mark' not listed in: $ERR" ;; esac
  git reset -q --hard "$pre"
done
amend 'val skipped = 1' '// xit is a switched-off test in some runners'
expect "lines that only mention skipping pass" 0 qa-amend 5
git reset -q --hard "$pre"

# the max+1 count: default 2 amendments, FACTORY_QA_AMEND_MAX
git reset -q --hard "$pre"
amend '// one'
expect "one amendment passes by default" 0 qa-amend 5
( export FACTORY_QA_AMEND_MAX=1; expect "one amendment passes with FACTORY_QA_AMEND_MAX=1" 0 qa-amend 5 )
( export FACTORY_QA_AMEND_MAX=0; expect "FACTORY_QA_AMEND_MAX=0 refuses the first amendment" 1 qa-amend 5 && has "says already amended 0 times" "qa-amend: the acceptance tests of #5 were already amended 0 times; the owner decides now" )
amend '// two'
expect "two amendments pass by default" 0 qa-amend 5
( export FACTORY_QA_AMEND_MAX=1; expect "FACTORY_QA_AMEND_MAX=1 refuses the second amendment" 1 qa-amend 5 && has "says already amended 1 times" "already amended 1 times" )
amend '// three'
expect "a third amendment is refused by default" 1 qa-amend 5 && has "says already amended 2 times" "qa-amend: the acceptance tests of #5 were already amended 2 times; the owner decides now"
( export FACTORY_QA_AMEND_MAX=3; expect "FACTORY_QA_AMEND_MAX=3 allows the third amendment" 0 qa-amend 5 )
( export FACTORY_LANGUAGE=pt-BR; expect "the refusal in pt-BR is still exit 1" 1 qa-amend 5 && has "pt-BR says the owner decides" "agora o owner decide" )
expect "a number that is no number is a usage error" 2 qa-amend x
has "usage names the gate" "usage: gate.sh qa-amend <n>"
expect "a number with a trailing letter is a usage error" 2 qa-amend 5x
expect "no number is a usage error" 2 qa-amend

# ======================= migration =======================
spec_with() { printf '# Spec\n\n## Rollback\n\n%s\n\n## Dúvidas\n\nnenhuma\n' "$1" > spec.md; }
mig_repo() {  # mig_repo <sql>: a repo whose card adds V2__x.sql with that content
  r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$M"; printf '%s\n' "$1" > "$M/V2__x.sql"
}
# ---- the ## Rollback rules
mig_repo 'alter table a drop column b;'
spec_with "$(printf '<!-- how to roll back -->')"
expect "a Rollback with only a one-line HTML comment is empty: blocked" 1 migration "$base" spec.md && has "says a filled Rollback is needed" "migration: destructive migration(s) $M/V2__x.sql need a filled '## Rollback' section in spec.md"
spec_with "$(printf '<!--\nexplain the way back\n-->\nRevert with V3, which recreates column b.')"
expect "a multi-line HTML comment and a real text passes" 0 migration "$base" spec.md
spec_with "$(printf 'Revert with V3.\n<!-- note\nfor the reviewer -->')"
expect "real text before a multi-line HTML comment passes" 0 migration "$base" spec.md
spec_with "$(printf '<!-- one\nline -->\nnot applicable')"
expect "a multi-line comment then 'not applicable' is blocked" 1 migration "$base" spec.md
for body in "" "n/a" "N/A" "None." "none" "- not applicable" "* Not Applicable." "não se aplica" "  n/a  "; do
  spec_with "$body"; expect "Rollback '$body' is no rollback" 1 migration "$base" spec.md
done
spec_with "Revert with V3 (not applicable to old rows)."
expect "a text that merely contains 'not applicable' is a rollback" 0 migration "$base" spec.md
spec_with "n/a for the data; revert by recreating the column."
expect "a text that starts with n/a and goes on is a rollback" 0 migration "$base" spec.md
rm spec.md
expect "a destructive migration with no spec file is blocked" 1 migration "$base" spec.md
printf '# Spec\n\n## Product\n\nx\n' > spec.md
expect "a spec with no Rollback section is blocked" 1 migration "$base" spec.md
printf '# Spec\n\n## Rollback extra\n\nRevert with V3.\n\n## Other\n\nx\n' > spec.md
expect "a heading that starts with '## Rollback' counts" 0 migration "$base" spec.md

# ---- the destructive keywords
dest() {  # dest <label> <sql> <exit wanted>: the migration with that content, a Rollback of n/a
  mig_repo "$2"; spec_with "n/a"; expect "$1" "$3" migration "$base" spec.md
}
dest "drop is destructive" 'alter table a drop column b;' 1
dest "rename is destructive" 'ALTER TABLE a RENAME COLUMN b TO c;' 1
dest "truncate is destructive" 'TRUNCATE a;' 1
dest "delete is destructive" 'delete from a;' 1
dest "the keyword is matched in any case" 'Drop Table a;' 1
dest "a keyword inside a string counts" "INSERT INTO t VALUES ('please drop by');" 1
dest "a keyword inside a longer identifier (deleted_at) is not destructive" 'ALTER TABLE a ADD COLUMN deleted_at timestamp;' 0
dest "a keyword as a prefix (dropped) is not destructive" 'ALTER TABLE a ADD COLUMN dropped int;' 0
dest "a keyword after an underscore (soft_delete) is not destructive" 'ALTER TABLE a ADD COLUMN soft_delete int;' 0
dest "a comment line with a keyword is not code" '-- we drop nothing here' 0
dest "a comment line after spaces is still a comment" '   -- drop it' 0
dest "a keyword after code on the same line counts" 'select 1; -- drop' 1
# the comment prefix comes from the layer
mig_repo 'drop table a;'; spec_with "n/a"
expect "a destructive migration with n/a blocks" 1 migration "$base" spec.md
git add -A; git commit -qm "card migration"
expect "a committed destructive migration blocks too" 1 migration "$base" spec.md
spec_with "Revert with V3."
expect "...and a filled Rollback lets it through" 0 migration "$base" spec.md
# several migrations, one destructive: the message lists it
mig_repo 'create table b (id int);'; printf 'drop table b;\n' > "$M/V3__y.sql"; spec_with "n/a"
expect "one destructive among several blocks" 1 migration "$base" spec.md && has "lists the destructive file" "$M/V3__y.sql"
case "$ERR" in *"$M/V2__x.sql"*) fail "AC-7 the harmless migration is listed as destructive: $ERR" ;; *) pass "AC-7 only the destructive migration is listed" ;; esac

# ---- applied migrations are immutable; order and duplicates
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo 'create table a (id int);' > "$M/V1__a.sql"; git add -A; git commit -qm v1; base="$(git rev-parse HEAD)"
printf '# S\n\n## Rollback\n\nRevert.\n' > spec.md
rm "$M/V1__a.sql"
expect "deleting an applied migration (uncommitted) is blocked" 1 migration "$base" spec.md && has "says applied migrations are immutable" "$M/V1__a.sql already exists on the base; applied migrations are immutable (add a new file)"
git add -A; git commit -qm "delete V1"
expect "deleting an applied migration (committed) is blocked" 1 migration "$base" spec.md
git reset -q --hard "$base"; echo 'create table a (id bigint);' > "$M/V1__a.sql"
expect "editing an applied migration is blocked" 1 migration "$base" spec.md
git checkout -q -- "$M/V1__a.sql"
expect "no change to the applied migrations passes" 0 migration "$base" spec.md
echo 'create table b (id int);' > "$M/V1__b.sql"
expect "a card migration with the base's version is blocked" 1 migration "$base" spec.md && has "names the version" "$M/V1__b.sql: not newer than $M/V1__a.sql (on the base or main); use a higher version"
rm "$M/V1__b.sql"; echo 'create table b (id int);' > "$M/V2__b.sql"; echo 'create table c (id int);' > "$M/V2__c.sql"
expect "two card migrations with one version are blocked" 1 migration "$base" spec.md && has "says the version is used twice" "migration: version 2 is used by"
has "the trailer says why" "migration: versions of layer 'api' must be unique and newer than the base's"
rm "$M/V2__c.sql"; echo 'create table d (id int);' > "$M/V3__d.sql"
expect "increasing versions pass" 0 migration "$base" spec.md
git checkout -q -b side; git commit -q --allow-empty -m s; git checkout -q main; git commit -q --allow-empty -m m2
expect "a base that is not an ancestor of HEAD is exit 2" 2 migration "$(git rev-parse side)" spec.md && has "says it is not an ancestor" "migration: base $(git rev-parse side) is not an ancestor of HEAD"

# ---- a name with no version in the card is refused; a bad name already on main only warns
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; base="$(git rev-parse HEAD)"; printf '# S\n\n## Rollback\n\nn/a\n' > spec.md
echo x > "$M/Vlatest__oops.sql"
expect "a card migration with no version in its name is blocked" 1 migration "$base" spec.md && has "says no version in the name" "$M/Vlatest__oops.sql: no version in the name"
r="$(new_repo)"; cd "$r"; mkdir -p "$M" web; echo x > "$M/V26__a.sql"; echo x > "$M/Vlatest__x.sql"; echo x > "$M/V26__dup.sql"; git add -A; git commit -qm m
base="$(git rev-parse HEAD)"; printf '# S\n\n## Rollback\n\nn/a\n' > spec.md; echo x > web/a.ts
expect "bad names already on main do not stall a card with no migration" 0 migration "$base" spec.md
has "they are warnings, naming the file" "migration: warning (already on the base or main): $M/Vlatest__x.sql: no version in the name"
has "the duplicate version on main is a warning too" "migration: warning (already on the base or main): version 26 is used by"
echo x > "$M/V27__new.sql"
expect "the card's own migration passes next to main's bad names" 0 migration "$base" spec.md && has "the warnings are still printed" "migration: warning (already on the base or main)"

# ---- main took the version while the card was being built: origin/<project.main>, never FACTORY_MAIN
mainrepo() {
  r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; git add -A; git commit -qm v26; base="$(git rev-parse HEAD)"
  git checkout -q -b side; echo x > "$M/V27__main.sql"; git add -A; git commit -qm "main took V27"; git update-ref refs/remotes/origin/trunk HEAD
  git checkout -q main; git branch -q -D side; echo x > "$M/V27__card.sql"; printf '# S\n\n## Rollback\n\nn/a\n' > spec.md
}
CFG_TRUNK="$T/trunk.yml"; sed 's/^  repo: acme\/shop$/  repo: acme\/shop\n  main: trunk/' "$FIX" > "$CFG_TRUNK"
mainrepo
( export FACTORY_CONFIG="$CFG_TRUNK" FACTORY_MAIN=other; expect "project.main=trunk finds the V27 on origin/trunk, whatever FACTORY_MAIN says" 1 migration "$base" spec.md )
( export FACTORY_CONFIG="$CFG_TRUNK" FACTORY_MAIN=main; expect "project.main=trunk with FACTORY_MAIN=main still collides" 1 migration "$base" spec.md )
( export FACTORY_MAIN=trunk; expect "project.main=main does not look at origin/trunk, even with FACTORY_MAIN=trunk" 0 migration "$base" spec.md )
git update-ref refs/remotes/origin/main refs/remotes/origin/trunk
expect "project.main=main collides once origin/main has the V27" 1 migration "$base" spec.md

# ---- the version pattern is configurable, and up/down pairs are one migration
CFG_GO="$T/go.yml"; cat > "$CFG_GO" <<'EOF'
project: {name: x, repo: a/x}
board: {owner: a, number: 1}
layers:
  - {name: db, path: db/, test: t, ran: ok, tests: ['db/**/*_test.go'], migrations: {glob: 'db/migrations/*.sql', version: '^([0-9]+)_'}}
EOF
( export FACTORY_CONFIG="$CFG_GO"
  r="$(new_repo)"; cd "$r"; mkdir -p db/migrations; echo x > db/migrations/000027_a.up.sql; echo x > db/migrations/000027_a.down.sql; git add -A; git commit -qm m; base="$(git rev-parse HEAD)"
  printf '# S\n\n## Rollback\n\nn/a\n' > spec.md
  echo x > db/migrations/000028_b.up.sql; echo x > db/migrations/000028_b.down.sql
  expect "up/down pairs are one migration, not a duplicate version" 0 migration "$base" spec.md
  echo x > db/migrations/000027_c.up.sql
  expect "a card migration reusing 000027 is blocked" 1 migration "$base" spec.md )
finish
