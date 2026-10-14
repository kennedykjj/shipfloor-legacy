#!/usr/bin/env bash
# Characterization of gate.sh's static gates: fast, scope, test-plan, qa-amend, migration, and the helpers
# acceptance-intact leans on (owner_accepted, merged_with_main). AC-2 and AC-3 of #158. These pin what the Bash gate
# does today, before the Python port: every assertion passes against the current code.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
# the pid comes from a child (sh exec'd from the substitution, so its $PPID is this shell), not $BASHPID: bash 5.2 can run the inherited EXIT trap in a subshell
# killed right after fork while $BASHPID still reads the parent's pid, and that removed $T under the running test
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"
FIX="$FACTORY_DIR/test/fixture/factory.yml"
M=api/src/main/resources/db/migration

code_of() {  # code_of <command...>: the exit code, output discarded
  "$@" >/dev/null 2>&1; echo $?
}
expect() {  # expect <label> <exit code wanted> <command...>
  local label="$1" want="$2" got; shift 2
  got="$("$@" 2>"$T/err" >/dev/null; echo $?)"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label: exit $got, want $want: $(cat "$T/err")"; fi
}
says() {  # says <label> <text> <command...>: stderr of the command has the text
  local label="$1" text="$2" err; shift 2
  err="$("$@" 2>&1 >/dev/null)"
  case "$err" in *"$text"*) pass "$label" ;; *) fail "$label: no '$text' in: $err" ;; esac
}
lastline() { printf '%s' "${1##*$'\n'}"; }

# ======================= AC-2: fast =======================
# a migration already on the base: with no migration file at all in the tree, the migration check fails (a bug,
# not pinned: the last pipeline of migration_versions is a grep that finds nothing and pipefail is on)
r="$(new_repo)"; cd "$r"; mkdir -p "$M" api/src/test; echo 'create table a (id int);' > "$M/V1__a.sql"; git add -A; git commit -qm v1
base="$(git rev-parse HEAD)"
printf '# S\n\n## Rollback\n\nn/a\n' > spec.md
echo 'test' > api/src/test/ATest.kt; git add -A; git commit -qm "test(x): acceptance tests for #9"; qa="$(git rev-parse HEAD)"
echo impl > api/Impl.kt; git add -A; git commit -qm impl
expect "AC-2 fast with the qa argument passes when the acceptance tests are intact" 0 bash "$GATE" fast "$base" spec.md "$qa"
echo weakened > api/src/test/ATest.kt
expect "AC-2 fast with the qa argument blocks an edited acceptance test" 1 bash "$GATE" fast "$base" spec.md "$qa"
says "AC-2 fast names the edited acceptance test" "api/src/test/ATest.kt" bash "$GATE" fast "$base" spec.md "$qa"
expect "AC-2 fast without the qa argument does not check the acceptance tests" 0 bash "$GATE" fast "$base" spec.md
git checkout -q -- api/src/test/ATest.kt
expect "AC-2 fast with a qa argument that is no commit is exit 2" 2 bash "$GATE" fast "$base" spec.md deadbeef
expect "AC-2 fast with a base that is no commit is exit 2" 2 bash "$GATE" fast deadbeef spec.md
mkdir -p .github; echo x > .github/w.yml
expect "AC-2 fast still blocks a forbidden file" 1 bash "$GATE" fast "$base" spec.md "$qa"
rm -rf .github

# gate-fast answers with the wrong count: the config query failed, exit 2 (a stub python for that one query)
cat > "$T/fakepy" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = gate-fast ]; then n="${PIN_FAST_COUNT:-2}"; while [ "$n" -gt 0 ]; do printf 'x\0'; n=$(( n - 1 )); done; exit 0; fi
done
exec "$FACTORY_PYTHON" "$@"
EOF
chmod +x "$T/fakepy"
for n in 0 2 4; do
  out="$(PIN_FAST_COUNT=$n SHIPFLOOR_PY="$T/fakepy" bash "$GATE" fast "$base" spec.md "$qa" 2>&1 >/dev/null)"; code=$?
  [ "$code" = 2 ] && pass "AC-2 a gate-fast answer with $n values is exit 2" || fail "AC-2 gate-fast with $n values: exit $code: $out"
  case "$out" in *"gate: config query failed: gate-fast"*) pass "AC-2 a gate-fast answer with $n values says the query failed" ;; *) fail "AC-2 gate-fast message: $out" ;; esac
  [ "$(lastline "$out")" = "gate fast: FAIL (exit 2)" ] && pass "AC-2 a gate-fast answer with $n values ends with 'gate fast: FAIL (exit 2)'" || fail "AC-2 last line: $(lastline "$out")"
done

# ======================= AC-2: qa-amend =======================
ATEST=api/src/test/ATest.kt
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/5-x
printf '%s\n' 'fun a() {' '  assertEquals(1, one())' '}' > "$ATEST"
git add -A; git commit -qm "test(x): acceptance tests for #5"
echo impl > api/Impl.kt; git add -A; git commit -qm "feat(api): impl"; pre="$(git rev-parse HEAD)"
amend() { printf '%s\n' "$@" >> "$ATEST"; git commit -qam "test(x): acceptance tests for #5"; }

# FACTORY_QA_AMEND_MAX: the number of amendments a card may have (default 2)
amend '// one'                                     # 2 QA commits
expect "AC-2 qa-amend: one amendment passes by default" 0 bash "$GATE" qa-amend 5
expect "AC-2 qa-amend: one amendment passes with FACTORY_QA_AMEND_MAX=1" 0 env FACTORY_QA_AMEND_MAX=1 bash "$GATE" qa-amend 5
expect "AC-2 qa-amend: FACTORY_QA_AMEND_MAX=0 refuses the first amendment" 1 env FACTORY_QA_AMEND_MAX=0 bash "$GATE" qa-amend 5
says "AC-2 qa-amend: FACTORY_QA_AMEND_MAX=0 says 'already amended 0 times'" "already amended 0 times" env FACTORY_QA_AMEND_MAX=0 bash "$GATE" qa-amend 5
amend '// two'                                     # 3 QA commits
expect "AC-2 qa-amend: two amendments pass by default" 0 bash "$GATE" qa-amend 5
expect "AC-2 qa-amend: FACTORY_QA_AMEND_MAX=1 refuses the second amendment" 1 env FACTORY_QA_AMEND_MAX=1 bash "$GATE" qa-amend 5
says "AC-2 qa-amend: FACTORY_QA_AMEND_MAX=1 says 'already amended 1 times'" "already amended 1 times" env FACTORY_QA_AMEND_MAX=1 bash "$GATE" qa-amend 5
amend '// three'                                   # 4 QA commits
expect "AC-2 qa-amend: a third amendment is refused by default" 1 bash "$GATE" qa-amend 5
says "AC-2 qa-amend: the default says 'already amended 2 times'" "already amended 2 times" bash "$GATE" qa-amend 5
expect "AC-2 qa-amend: FACTORY_QA_AMEND_MAX=3 allows the third amendment" 0 env FACTORY_QA_AMEND_MAX=3 bash "$GATE" qa-amend 5
expect "AC-2 qa-amend: a number that is no number is a usage error" 2 bash "$GATE" qa-amend x

# SKIP_MARKS: every way of switching a test off, not only @Disabled
git reset -q --hard "$pre"
amend '// one'; one="$(git rev-parse HEAD)"; git reset -q --hard "$pre"
for mark in 'describe.only("a", fn)' 'it.skip("a", fn)' 'test.fixme("a", fn)' 'it.todo("a")' '@Ignore' '@Disabled' \
            'xit("a") {}' 'xdescribe("a") {}' 'xtest("a") {}' 't.Skip("later")' '@pytest.mark.skip'; do
  amend "$mark"
  err="$(bash "$GATE" qa-amend 5 2>&1 >/dev/null)"; code=$?
  if [ "$code" = 1 ]; then pass "AC-2 qa-amend refuses an amendment that adds '$mark'"; else fail "AC-2 qa-amend with '$mark': exit $code: $err"; fi
  case "$err" in *"qa-amend: the amendment switches a test off:"*"$mark"*) pass "AC-2 qa-amend names '$mark' as a test switched off" ;; *) fail "AC-2 qa-amend '$mark' message: $err" ;; esac
  git reset -q --hard "$pre"
done
amend 'val skipped = 1' '// xit is a switched-off test in some runners'
expect "AC-2 qa-amend lets through lines that only mention skipping" 0 bash "$GATE" qa-amend 5
git reset -q --hard "$pre"

# ======================= AC-2: scope with a tests-only layer as the role =======================
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
expect "AC-2 scope with a tests-only layer (e2e) as the role is exit 2" 2 bash "$GATE" scope e2e "$base"
says "AC-2 scope names the tests-only layer as an unknown role" "scope: unknown role 'e2e'" bash "$GATE" scope e2e "$base"
expect "AC-2 scope with a role that is no layer is exit 2" 2 bash "$GATE" scope nobody "$base"
expect "AC-2 scope without a role is exit 2" 2 bash "$GATE" scope

# ======================= AC-2: test-plan with a | in a cell =======================
spec() {  # spec <test plan rows...>: a spec with AC-1 and AC-2 and these table rows
  {
    printf '# x - spec\n\n## Product\n**Acceptance criteria**\n- **AC-1** - Given a, when b, then c\n- **AC-2** - Given d, when e, then f\n\n## Architecture\nx\n\n## Test plan\n_Tech Lead_\n\n| AC | Layer | Test file |\n|---|---|---|\n'
    printf '%s\n' "$@"
    printf '\n## Security\nn/a\n'
  } > spec.md
}
r="$(new_repo)"; cd "$r"
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B.kt` (a or b) |'
expect "AC-2 test-plan: a plan without a | in a cell passes (control)" 0 bash "$GATE" test-plan spec.md
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B.kt` (a|b) |'
expect "AC-2 test-plan: a | in a cell after the file cell does not change the answer" 0 bash "$GATE" test-plan spec.md
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B.kt` (a\|b) | a\|b |'
expect "AC-2 test-plan: an escaped \\| in a cell after the file cell does not change the answer" 0 bash "$GATE" test-plan spec.md
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B|C.kt` |'
expect "AC-2 test-plan: a | inside the file path splits the cell: no path, blocked" 1 bash "$GATE" test-plan spec.md
says "AC-2 test-plan: a | inside the file path says there is no path" "'no path' is not a test file of layer 'api'" bash "$GATE" test-plan spec.md

# ======================= AC-2: ## Rollback =======================
spec_with() { printf '# Spec\n\n## Rollback\n\n%s\n\n## Dúvidas\n\nnenhuma\n' "$1" > spec.md; }
mig_repo() {  # mig_repo <sql>: a repo whose card adds V2__x.sql with that content
  r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$M"; printf '%s\n' "$1" > "$M/V2__x.sql"
}
mig_repo 'alter table a drop column b;'
spec_with "$(printf '<!-- how to roll back -->')"
expect "AC-2 migration: a Rollback with only a one-line HTML comment is empty: blocked" 1 bash "$GATE" migration "$base" spec.md
spec_with "$(printf '<!--\nexplain the way back\n-->\nRevert with V3, which recreates column b.')"
expect "AC-2 migration: a Rollback with a multi-line HTML comment and a real text passes" 0 bash "$GATE" migration "$base" spec.md
spec_with "$(printf 'Revert with V3.\n<!-- note\nfor the reviewer -->')"
expect "AC-2 migration: real text before a multi-line HTML comment passes" 0 bash "$GATE" migration "$base" spec.md
spec_with "$(printf '<!-- one\nline -->\nnot applicable')"
expect "AC-2 migration: a multi-line comment then 'not applicable' is blocked" 1 bash "$GATE" migration "$base" spec.md
spec_with ""
expect "AC-2 migration: an empty Rollback is blocked" 1 bash "$GATE" migration "$base" spec.md
rm spec.md
expect "AC-2 migration: a destructive migration with no spec file is blocked" 1 bash "$GATE" migration "$base" spec.md
mig_repo "INSERT INTO t VALUES ('please drop by');"; spec_with "n/a"
expect "AC-2 migration: a destructive keyword inside a string counts as destructive" 1 bash "$GATE" migration "$base" spec.md
spec_with "Revert by deleting the row."
expect "AC-2 migration: ...and a filled Rollback lets it through" 0 bash "$GATE" migration "$base" spec.md
mig_repo 'ALTER TABLE a ADD COLUMN deleted_at timestamp;'; spec_with "n/a"
expect "AC-2 migration: a keyword inside a longer identifier (deleted_at) is not destructive" 0 bash "$GATE" migration "$base" spec.md
mig_repo 'Drop Table a;'; spec_with "n/a"
expect "AC-2 migration: the keyword is matched in any case" 1 bash "$GATE" migration "$base" spec.md
mig_repo 'TRUNCATE a;'; spec_with "None."
expect "AC-2 migration: 'None.' is no rollback" 1 bash "$GATE" migration "$base" spec.md
spec_with "- not applicable"
expect "AC-2 migration: '- not applicable' is no rollback" 1 bash "$GATE" migration "$base" spec.md

# ======================= AC-3: migration deleting an applied file =======================
r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo 'create table a (id int);' > "$M/V1__a.sql"; git add -A; git commit -qm v1; base="$(git rev-parse HEAD)"
printf '# S\n\n## Rollback\n\nRevert.\n' > spec.md
rm "$M/V1__a.sql"
expect "AC-3 migration: deleting an applied migration (uncommitted) is blocked" 1 bash "$GATE" migration "$base" spec.md
says "AC-3 migration: the message says applied migrations are immutable" "already exists on the base; applied migrations are immutable" bash "$GATE" migration "$base" spec.md
git add -A; git commit -qm "delete V1"
expect "AC-3 migration: deleting an applied migration (committed) is blocked" 1 bash "$GATE" migration "$base" spec.md
git reset -q --hard "$base"; echo 'create table a (id bigint);' > "$M/V1__a.sql"
expect "AC-3 migration: editing an applied migration is blocked" 1 bash "$GATE" migration "$base" spec.md
git checkout -q -- "$M/V1__a.sql"
expect "AC-3 migration: no change to the applied migrations passes" 0 bash "$GATE" migration "$base" spec.md

# ======================= AC-3: FACTORY_MAIN and project.main =======================
# migration reads origin/<project.main> (the config), never FACTORY_MAIN
mainrepo() {  # mainrepo: V26 on main; origin/trunk holds a V27 main took meanwhile; the card adds its own V27 (uncommitted)
  r="$(new_repo)"; cd "$r"; mkdir -p "$M"; echo x > "$M/V26__a.sql"; git add -A; git commit -qm v26; base="$(git rev-parse HEAD)"
  git checkout -q -b side; echo x > "$M/V27__main.sql"; git add -A; git commit -qm "main took V27"; git update-ref refs/remotes/origin/trunk HEAD
  git checkout -q main; git branch -q -D side; echo x > "$M/V27__card.sql"
  printf '# S\n\n## Rollback\n\nn/a\n' > spec.md
}
CFG_TRUNK="$(mktemp)"; sed 's/^  repo: acme\/shop$/  repo: acme\/shop\n  main: trunk/' "$FIX" > "$CFG_TRUNK"
grep -q '^  main: trunk$' "$CFG_TRUNK" && pass "AC-3 fixture gets project.main: trunk" || fail "AC-3 could not set project.main in the fixture"
mainrepo
expect "AC-3 migration: project.main=trunk finds the V27 on origin/trunk (collision), whatever FACTORY_MAIN says" 1 env FACTORY_CONFIG="$CFG_TRUNK" FACTORY_MAIN=other bash "$GATE" migration "$base" spec.md
expect "AC-3 migration: project.main=trunk with FACTORY_MAIN=main still collides" 1 env FACTORY_CONFIG="$CFG_TRUNK" FACTORY_MAIN=main bash "$GATE" migration "$base" spec.md
expect "AC-3 migration: project.main=main (default) does not look at origin/trunk, even with FACTORY_MAIN=trunk" 0 env FACTORY_MAIN=trunk bash "$GATE" migration "$base" spec.md
git update-ref refs/remotes/origin/main refs/remotes/origin/trunk
expect "AC-3 migration: project.main=main collides once origin/main has the V27" 1 bash "$GATE" migration "$base" spec.md

# acceptance-intact reads FACTORY_MAIN (local or origin/): the shared test file QA and main both edit
TF=api/src/test/SharedTest.kt
shared() { printf '%s\n' 'class SharedTest {' "$@" '}' > "$TF"; }
shared_repo() {  # shared_repo: feat/7-x merged with main, which added fromMain(); prints nothing, sets qa and the refs c_base c_main
  r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
  shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git add -A; git commit -qm shared; c_base="$(git rev-parse HEAD)"
  git checkout -q -b feat/7-x
  shared '  fun old1() {}' '' '  fun old2() {}' '' '  fun old3() {}' '' '  fun acceptance7() { check() }'
  git commit -qam "test(x): acceptance tests for #7"; qa="$(git rev-parse HEAD)"
  git checkout -q main
  shared '  fun old1() {}' '' '  fun fromMain() {}' '' '  fun old2() {}' '' '  fun old3() {}'; git commit -qam "main adds a test"; c_main="$(git rev-parse HEAD)"
  git checkout -q feat/7-x; git merge -q --no-edit main
}
shared_repo
# AC-3 merged_with_main: only a local main exists (no origin/main)
[ -z "$(git for-each-ref refs/remotes)" ] && pass "AC-3 the repo has no origin/main" || fail "AC-3 unexpected remote refs"
expect "AC-3 merged_with_main: with only a local main, what main brought is not the card's edit" 0 bash "$GATE" acceptance-intact "$qa"
git update-ref refs/remotes/origin/main "$c_main"
expect "AC-3 merged_with_main: origin/main at the same commit gives the same answer" 0 bash "$GATE" acceptance-intact "$qa"
git update-ref refs/remotes/origin/main "$c_base"
expect "AC-3 merged_with_main: origin/main (stale) is preferred to the local main: main 'brought nothing', blocked" 1 bash "$GATE" acceptance-intact "$qa"
git update-ref -d refs/remotes/origin/main
# FACTORY_MAIN names the main branch
git branch -q -m main trunk
expect "AC-3 FACTORY_MAIN: with no branch called main the merge from main is not recognized: blocked" 1 bash "$GATE" acceptance-intact "$qa"
expect "AC-3 FACTORY_MAIN=trunk: the local trunk is the main branch: passes" 0 env FACTORY_MAIN=trunk bash "$GATE" acceptance-intact "$qa"
git update-ref refs/remotes/origin/trunk "$c_main"
expect "AC-3 FACTORY_MAIN=trunk: origin/trunk is found too" 0 env FACTORY_MAIN=trunk bash "$GATE" acceptance-intact "$qa"
expect "AC-3 FACTORY_MAIN=other: no such branch: blocked" 1 env FACTORY_MAIN=other bash "$GATE" acceptance-intact "$qa"

# ======================= AC-3: owner_accepted with FACTORY_HOME unset =======================
# a merge that needed a hand resolution: only the owner's record (FACTORY_HOME/accepted.tsv) lets it through
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test
shared '  fun a() { one() }'; git add -A; git commit -qm shared
git checkout -q -b feat/8-x; shared '  fun a() { qa() }'; git commit -qam "test(x): acceptance tests for #8"; qa="$(git rev-parse HEAD)"
git checkout -q main; shared '  fun a() { main() }'; git commit -qam "main edits the same line"
git checkout -q feat/8-x; git merge -q --no-edit main >/dev/null 2>&1
shared '  fun a() { main() }'; git commit -qam resolved
expect "AC-3 owner_accepted: a hand-resolved merge with no record is blocked" 1 bash "$GATE" acceptance-intact "$qa"
printf '%s\t%s\t#8\t2026-10-10\treworded\n' "$TF" "$(git rev-parse "HEAD:$TF")" > "$FACTORY_HOME/accepted.tsv"
expect "AC-3 owner_accepted: the record in FACTORY_HOME/accepted.tsv lets it through" 0 bash "$GATE" acceptance-intact "$qa"
out="$(env -u FACTORY_HOME bash "$GATE" acceptance-intact "$qa" 2>&1 >/dev/null)"; code=$?
[ "$code" = 1 ] && pass "AC-3 owner_accepted: with FACTORY_HOME unset the record is not found: blocked, not a crash" || fail "AC-3 FACTORY_HOME unset: exit $code: $out"
[ "$(lastline "$out")" = "gate acceptance-intact: FAIL (exit 1)" ] && pass "AC-3 owner_accepted: FACTORY_HOME unset ends with the FAIL verdict" || fail "AC-3 last line: $(lastline "$out")"
case "$out" in *"unbound variable"*) fail "AC-3 FACTORY_HOME unset: unbound variable: $out" ;; *) pass "AC-3 owner_accepted: FACTORY_HOME unset trips no unbound variable" ;; esac
case "$out" in *"$TF"*) pass "AC-3 owner_accepted: the blocked file is named" ;; *) fail "AC-3 no file named: $out" ;; esac
printf '%s\tdeleted\t#8\t2026-10-10\tgone\n' api/src/test/Gone.kt > "$FACTORY_HOME/accepted.tsv"
expect "AC-3 owner_accepted: a record for another file does not accept this one" 1 bash "$GATE" acceptance-intact "$qa"
rm -f "$FACTORY_HOME/accepted.tsv"
finish
