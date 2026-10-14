#!/usr/bin/env bash
# AC-2 of #165: the Python static gates exit 0 (pass), 1 (blocked), 2 (bad usage, bad revision, failed config query,
# invalid ERE) as the Bash gate does, and an `exit` inside a check ends the whole gate (nothing after it runs).
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
FIX="$FACTORY_DIR/test/fixture/factory.yml"
M=api/src/main/resources/db/migration
[ -f "$FACTORY_DIR/test/fixtures/gate.bash.sh" ] && [ "$(git hash-object "$FACTORY_DIR/test/fixtures/gate.bash.sh")" = 5e5faa4675c8b4caceaafece8859253a00da76b0 ] || { fail "AC-2 the reference Bash gate fixture is missing or not the pre-port gate.sh"; exit 1; }
REF="$(plugin_copy)"; cp "$FACTORY_DIR/test/fixtures/gate.bash.sh" "$REF/scripts/gate.sh"
refgate() { bash "$REF/scripts/gate.sh" "$@"; }
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
pygate --help >/dev/null 2>&1 || { fail "AC-2 the Python gate is missing: 'sf.py gate --help' fails, so no exit code of it can be checked"; exit 1; }

expect() {  # expect <label> <exit wanted> <gate args...>: the Python gate's exit code
  local label="$1" want="$2" got; shift 2
  pygate "$@" >"$T/out" 2>"$T/err"; got=$?
  case "$(cat "$T/err")" in "usage: sf.py"*) fail "AC-2 $label: sf.py has no gate command: $(cat "$T/err")"; return ;; esac
  if [ "$got" = "$want" ]; then pass "AC-2 $label"; else fail "AC-2 $label: python gate exit $got, want $want: $(head -c 300 "$T/err")"; fi
}
says() {  # says <label> <text> <gate args...>: the Python gate's stderr has the text
  local label="$1" text="$2" err; shift 2
  err="$(pygate "$@" 2>&1 >/dev/null)"
  case "$err" in *"$text"*) pass "AC-2 $label" ;; *) fail "AC-2 $label: no '$text' in: $err" ;; esac
}
lastline() { printf '%s' "${1##*$'\n'}"; }
ends() {  # ends <label> <last stderr line> <gate args...>
  local label="$1" want="$2" err; shift 2
  err="$(pygate "$@" 2>&1 >/dev/null)"
  [ "$(lastline "$err")" = "$want" ] && pass "AC-2 $label" || fail "AC-2 $label: last line '$(lastline "$err")', want '$want'"
}
like_ref() {  # like_ref <label> <gate args...>: same exit code as the Bash gate, which must not be 0
  local label="$1" want got; shift
  refgate "$@" >/dev/null 2>&1; want=$?
  pygate "$@" >"$T/out" 2>"$T/err"; got=$?
  case "$(cat "$T/err")" in "usage: sf.py"*) fail "AC-2 $label: sf.py has no gate command"; return ;; esac
  if [ "$got" = "$want" ]; then pass "AC-2 $label (exit $got, as the Bash gate)"; else fail "AC-2 $label: python gate exit $got, Bash gate $want: $(head -c 300 "$T/err")"; fi
}

# ---- 0 pass, 1 blocked
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p api/src/main web .github
printf '**Weight:** light\n\n## Product\n' > "$T/good.md"; printf '# no weight\n' > "$T/bad.md"
expect "weight passes: exit 0" 0 weight "$T/good.md"
expect "weight blocks: exit 1" 1 weight "$T/bad.md"
echo x > api/src/main/A.kt
expect "scope api passes: exit 0" 0 scope api "$base"
expect "scope web blocks: exit 1" 1 scope web "$base"
expect "forbidden passes: exit 0" 0 forbidden "$base"
echo x > .github/w.yml
expect "forbidden blocks: exit 1" 1 forbidden "$base"
rm -rf .github

# ---- 2: bad usage, bad revision, unknown layer
expect "no argument is exit 2" 2
expect "an unknown command is exit 2" 2 bogus
expect "scope without a role is exit 2" 2 scope
expect "scope with an unknown role is exit 2" 2 scope nobody "$base"
says "scope names the unknown role" "scope: unknown role 'nobody'" scope nobody "$base"
expect "scope with a tests-only layer as the role is exit 2" 2 scope e2e "$base"
expect "scope with a bad revision is exit 2" 2 scope api deadbeef
says "a bad revision says so" "gate: bad revision 'deadbeef'" scope api deadbeef
expect "forbidden without a base is exit 2" 2 forbidden
says "an empty revision says so" "gate: bad revision ''" forbidden
expect "qa-commit without a number is exit 2" 2 qa-commit
expect "qa-amend with a non-number is exit 2" 2 qa-amend x
says "qa-amend usage names gate.sh" "usage: gate.sh qa-amend <n>" qa-amend x
expect "acceptance-intact with a bad revision is exit 2" 2 acceptance-intact deadbeef
expect "acceptance-own with a bad revision is exit 2" 2 acceptance-own deadbeef x
expect "migration with a bad revision is exit 2" 2 migration deadbeef spec.md
expect "fast with a bad revision is exit 2" 2 fast deadbeef spec.md
expect "weight with a missing spec is exit 2" 2 weight nothing.md
expect "test-plan with a missing spec is exit 2" 2 test-plan nothing.md
expect "-C into a missing directory is exit 2" 2 -C "$T/missing" weight "$T/good.md"
expect "help is exit 0" 0 --help

# ---- 2: project or config failures
( unset FACTORY_CONFIG; expect "an unregistered project is exit 2" 2 weight "$T/good.md" )
BADCFG="$T/bad.yml"; printf 'project: [this is not valid\n' > "$BADCFG"
( export FACTORY_CONFIG="$BADCFG"; expect "a broken config is exit 2" 2 scope api "$base" )
# an invalid ERE in a config value the gate hands to grep -E: the code is what the Bash gate gives
r="$(new_repo)"; cd "$r"; mkdir -p api/src/test; git checkout -q -b feat/10-x
printf '%s\n' 'fun a() {' '  assertEquals(1, one())' '}' > api/src/test/ATest.kt; git add -A; git commit -qm "test(x): acceptance tests for #10"; qa="$(git rev-parse HEAD)"
printf '%s\n' '// c' >> api/src/test/ATest.kt; git commit -qam "edit"
BADRE="$T/bad-re.yml"; { cat "$FIX"; echo "acceptance_assertions: '('"; } > "$BADRE"
( export FACTORY_CONFIG="$BADRE"; like_ref "acceptance-intact with an invalid ERE in acceptance_assertions" acceptance-intact "$qa" )

# ---- an exit inside a check ends the whole gate
# fast: forbidden, migration, acceptance-intact run in turn; a bad qa revision is exit 2 and nothing else is said
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p "$M"; echo 'create table a (id int);' > "$M/V1__a.sql"; git add -A; git commit -qm v1; base="$(git rev-parse HEAD)"
printf '# S\n\n## Rollback\n\nn/a\n' > spec.md; echo 'drop table a;' > "$M/V2__x.sql"
expect "fast: the migration check blocks (exit 1)" 1 fast "$base" spec.md
printf '# S\n\n## Rollback\n\nRevert with V3.\n' > spec.md
expect "fast with a qa that is no commit is exit 2" 2 fast "$base" spec.md deadbeef
git checkout -q -b side; git rm -q -r "$M"; git commit -qm x; git checkout -q main
# the migration check exits 2 (the base is not an ancestor): the acceptance check after it never runs
out="$(pygate fast "$(git rev-parse side)" spec.md deadbeef 2>&1)"
case "$out" in *"bad revision 'deadbeef'"*) fail "AC-2 fast: acceptance-intact ran after the exit 2 of the migration check: $out" ;; *"is not an ancestor"*) pass "AC-2 an exit inside a check ends the whole gate (fast stops at the migration check)" ;; *) fail "AC-2 fast stop: $out" ;; esac
expect "migration with a base that is not an ancestor of HEAD is exit 2" 2 migration "$(git rev-parse side)" spec.md
ends "an exit 2 inside the migration check still ends with the FAIL verdict" "gate migration: FAIL (exit 2)" migration "$(git rev-parse side)" spec.md
ends "qa-amend usage ends with the FAIL verdict (exit 2)" "gate qa-amend: FAIL (exit 2)" qa-amend x
ends "a bad revision ends with the FAIL verdict (exit 2)" "gate forbidden: FAIL (exit 2)" forbidden deadbeef
printf '# no weight\n' > bad.md
ends "a block ends with the FAIL verdict (exit 1)" "gate weight: FAIL (exit 1)" weight bad.md
finish
