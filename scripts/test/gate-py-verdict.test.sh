#!/usr/bin/env bash
# AC-3 of #165: a Python static gate that reaches a verdict ends stderr with the English "gate <name>: pass|FAIL (exit N)"
# (exit 2 shows as FAIL) and writes it to $SHIPFLOOR_RUN_LOCK/last-gate only when that directory exists. No verdict for a
# resolve or -C failure, for usage with no argument, for acceptance-own, or for stack.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
pygate --help >/dev/null 2>&1 || { fail "AC-3 the Python gate is missing: 'sf.py gate --help' fails, so it has no verdict to check"; exit 1; }

run() {  # run <gate args...>: OUT, ERR, CODE of the Python gate
  OUT="$(pygate "$@" 2>"$T/err")"; CODE=$?; ERR="$(cat "$T/err")"
  case "$ERR" in "usage: sf.py"*) fail "AC-3 sf.py has no gate command: $ERR"; return 1 ;; esac
}
lastline() { printf '%s' "${1##*$'\n'}"; }
lock="$(mktemp -d)"
lastgate() { cat "$lock/last-gate" 2>/dev/null; }
inrun() { SHIPFLOOR_RUN_LOCK="$lock" run "$@"; }

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
printf '**Weight:** light\n\n## Product\n' > good.md; printf '# no weight\n' > bad.md

# ---- pass and block
rm -f "$lock/last-gate"; inrun weight good.md
[ "$CODE" = 0 ] && [ "$(lastline "$ERR")" = "gate weight: pass" ] && pass "AC-3 a passing gate ends stderr with 'gate weight: pass'" || fail "AC-3 pass: exit $CODE, stderr: $ERR"
[ "$(lastgate)" = "$(printf 'weight\tpass')" ] && pass "AC-3 last-gate records 'weight<TAB>pass'" || fail "AC-3 last-gate: '$(lastgate)'"
rm -f "$lock/last-gate"; inrun weight bad.md
[ "$CODE" = 1 ] && [ "$(lastline "$ERR")" = "gate weight: FAIL (exit 1)" ] && pass "AC-3 a blocked gate ends stderr with 'gate weight: FAIL (exit 1)'" || fail "AC-3 block: exit $CODE, stderr: $ERR"
[ "$(lastgate)" = "$(printf 'weight\tFAIL')" ] && pass "AC-3 last-gate records 'weight<TAB>FAIL'" || fail "AC-3 last-gate: '$(lastgate)'"
rm -f "$lock/last-gate"; inrun forbidden deadbeef
[ "$CODE" = 2 ] && [ "$(lastline "$ERR")" = "gate forbidden: FAIL (exit 2)" ] && pass "AC-3 a bad revision (exit 2) ends with 'gate forbidden: FAIL (exit 2)'" || fail "AC-3 exit 2: exit $CODE, stderr: $ERR"
[ "$(lastgate)" = "$(printf 'forbidden\tFAIL')" ] && pass "AC-3 last-gate records exit 2 as FAIL" || fail "AC-3 last-gate: '$(lastgate)'"
rm -f "$lock/last-gate"; inrun scope nobody "$base"
[ "$CODE" = 2 ] && [ "$(lastline "$ERR")" = "gate scope: FAIL (exit 2)" ] && pass "AC-3 an unknown role ends with 'gate scope: FAIL (exit 2)'" || fail "AC-3 scope: exit $CODE, stderr: $ERR"
[ -z "$OUT" ] && pass "AC-3 a verdict puts nothing on stdout" || fail "AC-3 stdout: $OUT"

# ---- the name in the verdict is the raw name given
rm -f "$lock/last-gate"; inrun qa-commit
[ "$(lastline "$ERR")" = "gate qa-commit: FAIL (exit 2)" ] && pass "AC-3 the verdict carries the command's name (qa-commit)" || fail "AC-3 qa-commit: $ERR"
rm -f "$lock/last-gate"; inrun test-plan nothing.md
[ "$(lastline "$ERR")" = "gate test-plan: FAIL (exit 2)" ] && [ "$(lastgate)" = "$(printf 'test-plan\tFAIL')" ] && pass "AC-3 test-plan with a missing spec is exit 2 shown as FAIL" || fail "AC-3 test-plan: $ERR / $(lastgate)"

# ---- outside a factory run no last-gate is written; a lock that is not there is not created
rm -f "$lock/last-gate"; run weight good.md
[ "$CODE" = 0 ] && [ "$(lastline "$ERR")" = "gate weight: pass" ] && [ ! -e "$lock/last-gate" ] && pass "AC-3 with no SHIPFLOOR_RUN_LOCK the verdict is printed and no last-gate is written" || fail "AC-3 no lock: exit $CODE, last-gate '$(lastgate)', stderr: $ERR"
SHIPFLOOR_RUN_LOCK="$T/no-such-lock" run weight good.md
[ "$CODE" = 0 ] && [ ! -e "$T/no-such-lock" ] && pass "AC-3 a SHIPFLOOR_RUN_LOCK that is no directory gets no last-gate (and is not created)" || fail "AC-3 missing lock: exit $CODE, $(ls "$T" 2>&1)"

# ---- no verdict when resolve fails or -C fails
rm -f "$lock/last-gate"
OUT="$( unset FACTORY_CONFIG; export SHIPFLOOR_RUN_LOCK="$lock"; pygate weight good.md 2>"$T/err" )"; CODE=$?; ERR="$(cat "$T/err")"
[ "$CODE" = 2 ] && pass "AC-3 an unregistered project is exit 2" || fail "AC-3 unresolved: exit $CODE, stderr: $ERR"
case "$ERR" in *"is not in a registered project"*) pass "AC-3 resolve says the project is not registered" ;; *) fail "AC-3 unresolved message: $ERR" ;; esac
case "$ERR" in *"gate weight:"*) fail "AC-3 a verdict after a failed resolve: $ERR" ;; *) pass "AC-3 no verdict line after a failed resolve" ;; esac
[ ! -e "$lock/last-gate" ] && pass "AC-3 no last-gate after a failed resolve" || fail "AC-3 last-gate after a failed resolve: $(lastgate)"
inrun -C "$T/does-not-exist" weight good.md
[ "$CODE" = 2 ] && pass "AC-3 -C into a missing directory is exit 2" || fail "AC-3 -C: exit $CODE, stderr: $ERR"
case "$ERR" in *"gate: cannot enter '$T/does-not-exist'"*) pass "AC-3 -C says it cannot enter the directory" ;; *) fail "AC-3 -C message: $ERR" ;; esac
case "$ERR" in *"gate weight:"*) fail "AC-3 a verdict after a failed -C: $ERR" ;; *) pass "AC-3 no verdict line after a failed -C" ;; esac
[ ! -e "$lock/last-gate" ] && pass "AC-3 no last-gate after a failed -C" || fail "AC-3 last-gate after a failed -C: $(lastgate)"
run -C "$r" weight good.md
[ "$CODE" = 0 ] && [ "$(lastline "$ERR")" = "gate weight: pass" ] && pass "AC-3 -C into a real directory runs the gate there and says its verdict" || fail "AC-3 -C into the repo: exit $CODE, stderr: $ERR"

# ---- help and no argument: no verdict
run help
[ "$CODE" = 0 ] && case "$OUT" in "usage: gate.sh"*) true ;; *) false ;; esac && [ -z "$ERR" ] && pass "AC-3 help prints the usage on stdout, nothing on stderr" || fail "AC-3 help: exit $CODE, stdout '$OUT', stderr '$ERR'"
rm -f "$lock/last-gate"; inrun
[ "$CODE" = 2 ] && case "$ERR" in "usage: gate.sh"*) true ;; *) false ;; esac && [ -z "$OUT" ] && pass "AC-3 no argument exits 2 with the usage on stderr" || fail "AC-3 no argument: exit $CODE, stderr '$ERR'"
case "$ERR" in *"gate "*": FAIL"*) fail "AC-3 no argument printed a verdict: $ERR" ;; *) pass "AC-3 no argument has no verdict line" ;; esac
[ ! -e "$lock/last-gate" ] && pass "AC-3 no argument writes no last-gate" || fail "AC-3 last-gate: $(lastgate)"
rm -f "$lock/last-gate"; inrun bogus
[ "$CODE" = 2 ] && [ "$(lastline "$ERR")" = "gate bogus: FAIL (exit 2)" ] && [ "$(lastgate)" = "$(printf 'bogus\tFAIL')" ] && pass "AC-3 an unknown command prints the usage, then 'gate bogus: FAIL (exit 2)', and records it" || fail "AC-3 unknown command: exit $CODE, stderr '$ERR', last-gate '$(lastgate)'"

# ---- acceptance-own: stdout is the key, no verdict, no last-gate
git checkout -q -b feat/14-x; mkdir -p web; echo t > web/b.test.ts; git add -A; git commit -qm "test(x): acceptance tests for #14"; qa="$(git rev-parse HEAD)"
echo edited > web/b.test.ts; git commit -qam "the card edits a test"
rm -f "$lock/last-gate"; inrun acceptance-own "$qa" web/b.test.ts
[[ "$OUT" =~ ^own:[0-9a-f]{40,64}$ ]] && [ "$CODE" = 0 ] && [ -z "$ERR" ] && [ ! -e "$lock/last-gate" ] && pass "AC-3 acceptance-own prints own:<hash>, no verdict line, no last-gate" || fail "AC-3 acceptance-own: exit $CODE, stdout '$OUT', stderr '$ERR'"
rm -f "$lock/last-gate"; inrun acceptance-own deadbeef web/b.test.ts
[ "$CODE" = 2 ] && case "$ERR" in *"gate acceptance-own:"*) false ;; *) true ;; esac && [ ! -e "$lock/last-gate" ] && pass "AC-3 acceptance-own with a bad revision (exit 2) still has no verdict" || fail "AC-3 acceptance-own bad rev: exit $CODE, stderr '$ERR'"

# ---- qa-commit: stdout is the sha, the verdict is on stderr
rm -f "$lock/last-gate"; inrun qa-commit 14
[ "$CODE" = 0 ] && [ "$OUT" = "$qa" ] && [ "$(lastline "$ERR")" = "gate qa-commit: pass" ] && [ "$(lastgate)" = "$(printf 'qa-commit\tpass')" ] && pass "AC-3 qa-commit prints the sha and passes" || fail "AC-3 qa-commit: exit $CODE, stdout '$OUT', stderr '$ERR'"

# ---- stack: no verdict line (it stays in Bash, behind the wrapper)
rm -f "$lock/last-gate"
SHIPFLOOR_RUN_LOCK="$lock" bash "$FACTORY_DIR/gate.sh" stack status >"$T/so" 2>"$T/se"
case "$(cat "$T/se")" in *"gate stack:"*) fail "AC-3 stack printed a verdict: $(cat "$T/se")" ;; *) pass "AC-3 stack gets no verdict line" ;; esac
[ ! -e "$lock/last-gate" ] && pass "AC-3 stack writes no last-gate" || fail "AC-3 stack last-gate: $(lastgate)"
finish
