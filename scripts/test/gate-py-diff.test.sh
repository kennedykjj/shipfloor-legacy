#!/usr/bin/env bash
# AC-1 of #165: the differential. Every static gate, on the scenario repos the gate tests build, runs through the Bash
# gate.sh kept as a fixture (test/fixtures/gate.bash.sh), through the Python gate (sf.py gate) and through the new
# gate.sh wrapper: exit code, stdout, stderr and last-gate match byte for byte, in English and in pt-BR.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
FIX="$FACTORY_DIR/test/fixture/factory.yml"
M=api/src/main/resources/db/migration

# the reference: the pre-port gate.sh, run from a copy of scripts/ so it finds lib/project.sh and lib/stack.sh
REF="$(plugin_copy)"
[ -f "$FACTORY_DIR/test/fixtures/gate.bash.sh" ] && [ "$(git hash-object "$FACTORY_DIR/test/fixtures/gate.bash.sh")" = 5e5faa4675c8b4caceaafece8859253a00da76b0 ] || { fail "AC-1 the reference Bash gate fixture is missing or not the pre-port gate.sh"; exit 1; }
cp "$FACTORY_DIR/test/fixtures/gate.bash.sh" "$REF/scripts/gate.sh"
refgate() { bash "$REF/scripts/gate.sh" "$@"; }
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
wrapgate() { bash "$FACTORY_DIR/gate.sh" "$@"; }
# without the Python gate every case below would fail the same way: say it once
pygate --help >/dev/null 2>&1 || { fail "AC-1 the Python gate is missing: 'sf.py gate --help' fails, so no static gate can match the Bash one"; exit 1; }

lastg() { cat "$1/last-gate" 2>/dev/null; }
one() {  # one <label> <lang> <runner> <lockdir> <gate args...>: OUT_<runner> files
  local label="$1" lang="$2" who="$3" lock="$4"; shift 4
  rm -rf "$lock"; mkdir -p "$lock"
  FACTORY_LANGUAGE="$lang" SHIPFLOOR_RUN_LOCK="$lock" "$who" "$@" >"$lock.out" 2>"$lock.err"; echo $? > "$lock.code"
}
same() {  # same <label> <gate args...>: python and wrapper == the Bash reference, in en and pt-BR
  local label="$1" lang who; shift
  for lang in en pt-BR; do
    one "$label" "$lang" refgate "$T/lr" "$@"
    for who in pygate wrapgate; do
      one "$label" "$lang" "$who" "$T/l-$who" "$@"
      if [ "$(cat "$T/lr.code")" != "$(cat "$T/l-$who.code")" ]; then
        fail "AC-1 $label ($lang, $who): exit $(cat "$T/l-$who.code"), bash gate exit $(cat "$T/lr.code"): $(head -c 300 "$T/l-$who.err")"
      elif ! cmp -s "$T/lr.out" "$T/l-$who.out"; then
        fail "AC-1 $label ($lang, $who): stdout differs: python '$(head -c 200 "$T/l-$who.out")' vs bash '$(head -c 200 "$T/lr.out")'"
      elif ! cmp -s "$T/lr.err" "$T/l-$who.err"; then
        fail "AC-1 $label ($lang, $who): stderr differs: python '$(head -c 300 "$T/l-$who.err")' vs bash '$(head -c 300 "$T/lr.err")'"
      elif [ "$(lastg "$T/lr")" != "$(lastg "$T/l-$who")" ]; then
        fail "AC-1 $label ($lang, $who): last-gate '$(lastg "$T/l-$who")' vs '$(lastg "$T/lr")'"
      else pass "AC-1 $label ($lang, $who) matches the Bash gate"; fi
    done
  done
}

# ---- the Python gate is really there, and its help is the Bash one
if out="$(pygate --help 2>"$T/herr")"; then
  [ "$out" = "$(refgate --help 2>/dev/null)" ] && pass "AC-1 the python gate prints the same help as the Bash one" || fail "AC-1 python gate help differs from the Bash help"
else fail "AC-1 python gate: 'sf.py gate --help' failed: $(cat "$T/herr")"; fi
[ -d "$FACTORY_DIR/shipfloor_core/gate" ] && pass "AC-1 shipfloor_core/gate exists" || fail "AC-1 scripts/shipfloor_core/gate/ does not exist"
case "$(cat "$FACTORY_DIR/gate.sh")" in *gate_scope*|*gate_migration*|*gate_acceptance_intact*) fail "AC-1 scripts/gate.sh still holds the Bash static gates" ;; *) pass "AC-1 scripts/gate.sh no longer holds the Bash static gates" ;; esac
same "help" help
same "no argument"
same "unknown command" bogus
same "-C into a missing directory" -C "$T/missing" weight x.md

# ---- scope and forbidden
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
mkdir -p api/src/main api/src/test web/e2e web/lib .github docs/superpowers/specs
printf 'ignored.log\n' > .gitignore; git add -A; git commit -qm ignore; base="$(git rev-parse HEAD)"
echo x > api/src/main/A.kt
for role in api web e2e qa po ux techlead nobody; do same "scope $role (api change)" scope "$role" "$base"; done
same "scope without a role" scope
same "scope with a bad revision" scope api deadbeef
same "scope without a base" scope api
same "forbidden clean" forbidden "$base"
same "forbidden without a base" forbidden
same "forbidden with a bad revision" forbidden deadbeef
echo x > ignored.log; same "scope ignores an untracked ignored file" scope api "$base"; rm ignored.log
echo x > .github/w.yml; same "forbidden .github (untracked)" forbidden "$base"; same "scope api with .github" scope api "$base"; same "scope po with .github" scope po "$base"
git add -A; git commit -qm "gh"; same "forbidden .github (committed)" forbidden "$base"; same "scope api (committed .github)" scope api "$base"
git rm -q -r --cached .github; rm -rf .github; git commit -qm "gh gone"; same "forbidden after the file is gone" forbidden "$base"
echo x > web/vitest.config.ts; same "scope web (test runner config)" scope web "$base"; rm web/vitest.config.ts
echo x > web/e2e/a.spec.ts; same "scope web (tests-only layer file)" scope web "$base"; same "scope qa (e2e file)" scope qa "$base"; rm web/e2e/a.spec.ts
echo x > docs/superpowers/specs/my\ spec.md; same "scope po (a name with a space)" scope po "$base"; same "scope api (spec file)" scope api "$base"; rm docs/superpowers/specs/my\ spec.md
mkdir -p .github; echo x > .github/ci.yml; git add -A; git commit -qm ci; base2="$(git rev-parse HEAD)"
git mv .github/ci.yml api/ci.yml
same "scope api (rename out of .github)" scope api "$base2"; same "forbidden (rename out of .github)" forbidden "$base2"
git reset -q --hard "$base2"
odd="api/src/main/odd"$'\n'"name.kt"; echo x > "$odd"
same "scope api (a name with a newline)" scope api "$base2"; same "forbidden (a name with a newline)" forbidden "$base2"; same "scope po (a name with a newline)" scope po "$base2"
rm "$odd"; odd="api/src/main/tab"$'\t'"name.kt"; echo x > "$odd"
same "forbidden (a name with a tab)" forbidden "$base2"; rm "$odd"
# config variants: an invalid ERE, a config that is not there
BADRE="$T/bad-re.yml"; { cat "$FIX"; echo "acceptance_assertions: '('"; } > "$BADRE"
( export FACTORY_CONFIG="$BADRE"; same "forbidden with an invalid acceptance_assertions" forbidden "$base2"; same "scope api with an invalid acceptance_assertions" scope api "$base2" )
( export FACTORY_CONFIG="$T/none.yml"; same "weight with a config that is not there" weight x.md )
( unset FACTORY_CONFIG; same "forbidden with no project" forbidden "$base2" )

# ---- acceptance-intact, acceptance-own, qa-commit, qa-amend
ATEST=api/src/test/ATest.kt
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/5-x
printf '%s\n' 'fun a() {' '  assertEquals(1, one())' '  assertTrue(ok())' '}' > "$ATEST"; echo 'fun b() { assertTrue(b()) }' > api/src/test/BTest.kt
git add -A; git commit -qm "test(x): acceptance tests for #5"; qa5="$(git rev-parse HEAD)"
same "qa-amend with one QA commit" qa-amend 5
same "qa-commit" qa-commit 5; same "qa-commit --head" qa-commit 5 --head; same "qa-commit missing" qa-commit 6; same "qa-commit usage" qa-commit; same "qa-commit usage x" qa-commit x
same "acceptance-intact intact" acceptance-intact "$qa5"; same "acceptance-intact without a revision" acceptance-intact; same "acceptance-intact bad revision" acceptance-intact deadbeef
echo impl > api/Impl.kt; git add -A; git commit -qm "feat(api): impl"
same "qa-amend with a last commit that is not QA's" qa-amend 5; same "qa-commit --head after impl" qa-commit 5 --head
same "acceptance-own without own edit" acceptance-own "$qa5" "$ATEST"
sed -i 's/assertEquals(1, one())/assertEquals(1, oneTrimmed())/' "$ATEST"; git commit -qam "test(x): acceptance tests for #5"; qa5b="$(git rev-parse HEAD)"
same "qa-amend honest amendment" qa-amend 5; same "qa-commit takes the amendment" qa-commit 5 --head; same "acceptance-intact on the amendment" acceptance-intact "$qa5b"
echo 'fun b() { }' > api/src/test/BTest.kt; git commit -qam "edits a test the amendment did not touch"
same "acceptance-intact blocks a test the amendment did not touch" acceptance-intact "$qa5b"; same "acceptance-own after an own edit" acceptance-own "$qa5b" api/src/test/BTest.kt
same "acceptance-own without a file" acceptance-own "$qa5b"; same "acceptance-own bad revision" acceptance-own deadbeef "$ATEST"
git reset -q --hard "$qa5b"
for mark in '@Disabled' 'it.skip("a", fn)' 'xit("a") {}'; do printf '%s\n' "$mark" >> "$ATEST"; git commit -qam "test(x): acceptance tests for #5"; same "qa-amend adds $mark" qa-amend 5; git reset -q --hard "$qa5b"; done
sed -i '/assertTrue(ok())/d' "$ATEST"; git commit -qam "test(x): acceptance tests for #5"; same "qa-amend drops an assertion" qa-amend 5; git reset -q --hard "$qa5b"
echo x >> api/Impl.kt; echo '// note' >> "$ATEST"; git commit -qam "test(x): acceptance tests for #5"; same "qa-amend touches a non-test" qa-amend 5; git reset -q --hard "$qa5b"
for i in two three; do echo "// $i" >> "$ATEST"; git commit -qam "test(x): acceptance tests for #5"; same "qa-amend after $i" qa-amend 5; done
( export FACTORY_QA_AMEND_MAX=0; same "qa-amend with FACTORY_QA_AMEND_MAX=0" qa-amend 5 )
same "qa-amend usage" qa-amend x

TF=api/src/test/SharedTest.kt
shared() { printf '%s\n' 'class SharedTest {' "$@" '}' > "$TF"; }
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git add -A; git commit -qm shared
git checkout -q -b feat/7-x; shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}' '' '  fun acceptance7() { check() }'
git commit -qam "test(x): acceptance tests for #7"; qa7="$(git rev-parse HEAD)"
git checkout -q main; shared '  fun old1() {}' '' '  fun fromMain() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git commit -qam "main adds a test"; cmain="$(git rev-parse HEAD)"
git checkout -q feat/7-x; git merge -q --no-edit main
same "acceptance-intact: a clean merge from main" acceptance-intact "$qa7"
git update-ref refs/remotes/origin/main "$cmain"; same "acceptance-intact: origin/main at main" acceptance-intact "$qa7"
sed -i 's/fun acceptance7() { check() }/fun acceptance7() { }/' "$TF"; git commit -qam weaken
same "acceptance-intact: an own edit after the merge" acceptance-intact "$qa7"; same "acceptance-own: after the merge" acceptance-own "$qa7" "$TF"
printf '%s\t%s\t#7\t2026-10-10\tok\n' "$TF" "$(bash "$FACTORY_DIR/gate.sh" acceptance-own "$qa7" "$TF")" > "$FACTORY_HOME/accepted.tsv"
same "acceptance-intact: the own edit accepted by its own: key" acceptance-intact "$qa7"; rm -f "$FACTORY_HOME/accepted.tsv"
( export FACTORY_MAIN=other; same "acceptance-intact: FACTORY_MAIN=other" acceptance-intact "$qa7" )

r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun a() { one() }'; git add -A; git commit -qm shared
git checkout -q -b feat/8-x; shared '  fun a() { qa() }'; git commit -qam "test(x): acceptance tests for #8"; qa8="$(git rev-parse HEAD)"
git checkout -q main; shared '  fun a() { main() }'; git commit -qam "main edits the same line"
git checkout -q feat/8-x; git merge -q --no-edit main >/dev/null 2>&1; shared '  fun a() { main() }'; git commit -qam resolved
same "acceptance-intact: a hand-resolved merge" acceptance-intact "$qa8"
printf '%s\t%s\t#8\t2026-10-10\tok\n' "$TF" "$(git rev-parse "HEAD:$TF")" > "$FACTORY_HOME/accepted.tsv"
same "acceptance-intact: accepted by blob" acceptance-intact "$qa8"
( unset FACTORY_HOME; same "acceptance-intact: FACTORY_HOME unset" acceptance-intact "$qa8" ); rm -f "$FACTORY_HOME/accepted.tsv"

for order in qa-first main-first; do
  r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
  shared '  fun old() {}'; git add -A; git commit -qm shared
  git checkout -q -b feat/12-x; shared '  fun old() {}' '' '  fun acceptance12() { check() }'; git commit -qam "test(x): acceptance tests for #12"; qa12="$(git rev-parse HEAD)"
  git checkout -q main; shared '  fun old() {}' '' '  fun fromMain() { other() }'; git commit -qam "main appends a test"
  git checkout -q feat/12-x; git merge -q --no-edit main >/dev/null 2>&1
  if [ "$order" = qa-first ]; then shared '  fun old() {}' '' '  fun acceptance12() { check() }' '' '  fun fromMain() { other() }'
  else shared '  fun old() {}' '' '  fun fromMain() { other() }' '' '  fun acceptance12() { check() }'; fi
  git commit -qam resolved; same "acceptance-intact: both sides kept ($order)" acceptance-intact "$qa12"
  shared '  fun old() {}' '' '  fun fromMain() { other() }' '' '  fun acceptance12() { }'; git commit -qam weaken; same "acceptance-intact: both sides, weakened ($order)" acceptance-intact "$qa12"
done

CFGA="$T/assertions.yml"; { cat "$FIX"; echo "acceptance_assertions: 'assert|expect\('"; } > "$CFGA"
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/10-x
shared '  fun a() {' '    val s = Service(repo)' '    assertEquals(1, s.count())' '  }'; git add -A; git commit -qm "test(x): acceptance tests for #10"; qa10="$(git rev-parse HEAD)"
shared '  fun a() {' '    val s = Service(repo, clock)' '    assertEquals(1, s.count())' '  }'; git commit -qam adapt
same "acceptance-intact: no acceptance_assertions" acceptance-intact "$qa10"
( export FACTORY_CONFIG="$CFGA"; same "acceptance-intact: acceptance_assertions lets the edit through" acceptance-intact "$qa10" )
shared '  fun a() {' '    val s = Service(repo, clock)' '  }'; git commit -qam drop
( export FACTORY_CONFIG="$CFGA"; same "acceptance-intact: acceptance_assertions, assertion dropped" acceptance-intact "$qa10" )
( export FACTORY_CONFIG="$BADRE"; same "acceptance-intact: an invalid ERE in acceptance_assertions" acceptance-intact "$qa10" )

r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
echo 'test' > api/src/test/ATest.kt; echo 'stub' > api/src/test/RedStubs.kt; git add -A; git commit -qm qa; qa9="$(git rev-parse HEAD)"
git rm -q api/src/test/RedStubs.kt; git commit -qm "stub replaced"
same "acceptance-intact: a deleted stub" acceptance-intact "$qa9"
printf '%s\tdeleted\t#9\t2026-10-10\tok\n' api/src/test/RedStubs.kt > "$FACTORY_HOME/accepted.tsv"
same "acceptance-intact: deletion accepted" acceptance-intact "$qa9"; rm api/src/test/ATest.kt; same "acceptance-intact: deleted, not committed" acceptance-intact "$qa9"; rm -f "$FACTORY_HOME/accepted.tsv"
git checkout -q -- .; git checkout -q -b empty; git commit -q --allow-empty -m empty; same "acceptance-intact: a QA commit with no files" acceptance-intact HEAD

# ---- migration and fast
spec_with() { printf '# Spec\n\n## Rollback\n\n%s\n\n## Dúvidas\n\nnenhuma\n' "$1" > spec.md; }
mig_repo() {  # mig_repo <sql>: a repo whose card adds V2__x.sql with that content
  r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo 'create table a (id int);' > "$M/V1__a.sql"; git add -A; git commit -qm v1; base="$(git rev-parse HEAD)"
  printf '%s\n' "$1" > "$M/V2__x.sql"
}
mig_repo 'alter table a drop column b;'
for body in '<!-- how to roll back -->' 'Revert with V3.' 'n/a' 'None.' '- not applicable' 'não se aplica' ''; do
  spec_with "$body"; same "migration destructive, Rollback '$body'" migration "$base" spec.md
done
spec_with "$(printf '<!--\nexplain\n-->\nRevert with V3.')"; same "migration with a multi-line comment and a text" migration "$base" spec.md
rm spec.md; same "migration destructive with no spec" migration "$base" spec.md; same "migration without a spec argument" migration "$base"
same "migration with a bad base" migration deadbeef spec.md; same "migration without arguments" migration
for sql in "INSERT INTO t VALUES ('please drop by');" 'ALTER TABLE a ADD COLUMN deleted_at timestamp;' 'Drop Table a;' '-- drop it' 'rename table a to b;'; do
  mig_repo "$sql"; spec_with "n/a"; same "migration sql '$sql'" migration "$base" spec.md
done
mig_repo 'create table b (id int);'; echo 'create table c (id int);' > "$M/V2__y.sql"; spec_with "n/a"; same "migration with a duplicate version" migration "$base" spec.md
mig_repo 'create table b (id int);'; echo 'create table c (id int);' > "$M/V0__old.sql"; same "migration with a version older than the base's" migration "$base" spec.md
mig_repo 'create table b (id int);'; echo 'create table a (id bigint);' > "$M/V1__a.sql"; same "migration edits an applied file" migration "$base" spec.md
rm "$M/V1__a.sql"; same "migration deletes an applied file" migration "$base" spec.md
mig_repo 'create table b (id int);'; git checkout -q -b side; git rm -q -r "$M"; git commit -qm x; git checkout -q main; same "migration, base not an ancestor" migration "$(git rev-parse side)" spec.md
mainrepo() {
  r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; git add -A; git commit -qm v26; base="$(git rev-parse HEAD)"
  git checkout -q -b side; echo x > "$M/V27__main.sql"; git add -A; git commit -qm "main took V27"; git update-ref refs/remotes/origin/trunk HEAD
  git checkout -q main; git branch -q -D side; echo x > "$M/V27__card.sql"; printf '# S\n\n## Rollback\n\nn/a\n' > spec.md
}
CFGT="$T/trunk.yml"; sed 's/^  repo: acme\/shop$/  repo: acme\/shop\n  main: trunk/' "$FIX" > "$CFGT"
mainrepo; same "migration, project.main=main, V27 only on origin/trunk" migration "$base" spec.md
( export FACTORY_CONFIG="$CFGT" FACTORY_MAIN=other; same "migration, project.main=trunk collides" migration "$base" spec.md )
git update-ref refs/remotes/origin/main refs/remotes/origin/trunk; same "migration, origin/main collides" migration "$base" spec.md
mig_repo 'create table b (id int);'; spec_with "n/a"
printf '# S\n\n## Rollback\n\nRevert.\n' > spec.md; qa=HEAD
same "fast" fast "$base" spec.md; same "fast with a bad base" fast deadbeef spec.md; same "fast with a bad qa" fast "$base" spec.md deadbeef
mkdir -p .github; echo x > .github/w.yml; same "fast with a forbidden file" fast "$base" spec.md; rm -rf .github
r="$(new_repo)"; cd "$r"; mkdir -p "$M" api/src/test; echo 'create table a (id int);' > "$M/V1__a.sql"; git add -A; git commit -qm v1; base="$(git rev-parse HEAD)"
printf '# S\n\n## Rollback\n\nn/a\n' > spec.md; echo test > api/src/test/ATest.kt; git add -A; git commit -qm "test(x): acceptance tests for #9"; qa="$(git rev-parse HEAD)"
same "fast with qa intact" fast "$base" spec.md "$qa"; echo weak > api/src/test/ATest.kt; same "fast with qa edited" fast "$base" spec.md "$qa"

# ---- test-plan and weight
spec() {
  {
    printf '# x - spec\n\n## Product\n**Acceptance criteria**\n- **AC-1** - Given a, when b, then c\n- **AC-2** - Given d, when e, then f\n\n## Architecture\nx\n\n## Test plan\n_Tech Lead_\n\n| AC | Layer | Test file |\n|---|---|---|\n'
    printf '%s\n' "$@"; printf '\n## Security\nn/a\n'
  } > spec.md
}
r="$(new_repo)"; cd "$r"
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B.kt` |'; same "test-plan good" test-plan spec.md
spec '| AC-1 | api | `api/src/test/A.kt` |'; same "test-plan missing AC-2" test-plan spec.md
spec '| AC-1 | api | `api/src/main/A.kt` |' '| AC-2 | nope | `x` |'; same "test-plan wrong path, unknown layer" test-plan spec.md
spec '| AC-1, AC-2 | e2e | `web/e2e/a.spec.ts` |'; same "test-plan e2e, two ACs in a row" test-plan spec.md
spec '| AC-1 | manual | n/a |' '| AC-2 | api | `api/src/test/B|C.kt` |'; same "test-plan manual, a | in the path" test-plan spec.md
same "test-plan without a spec" test-plan; same "test-plan with a missing spec" test-plan nothing.md
printf '**Weight:** light\n\n## Product\n' > spec.md; same "weight light" weight spec.md
printf '**Weight:** standard\r\n\r\n## Product\r\n' > spec.md; same "weight with CRLF" weight spec.md
printf '**Weight:** heavy\n**Weight:** light\n' > spec.md; same "weight twice" weight spec.md
printf '**Weight:** huge\n' > spec.md; same "weight unknown" weight spec.md
printf '# no weight\n' > spec.md; same "weight none" weight spec.md
printf '## Product\n**Weight:** light\n' > spec.md; same "weight after the first ##" weight spec.md
same "weight without a spec" weight; same "weight with a missing spec" weight nothing.md
finish
