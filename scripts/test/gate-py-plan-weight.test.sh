#!/usr/bin/env bash
# AC-8 of #165: the Python test-plan and weight gates say exactly what the Bash ones say (every message, exit code and
# the \r handling), weight needs no config query, and `gate.sh --help` prints the same usage, including
# `green <layer> <selector>` and `weight <spec>`.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
[ -f "$FACTORY_DIR/test/fixtures/gate.bash.sh" ] && [ "$(git hash-object "$FACTORY_DIR/test/fixtures/gate.bash.sh")" = 5e5faa4675c8b4caceaafece8859253a00da76b0 ] || { fail "AC-8 the reference Bash gate fixture is missing or not the pre-port gate.sh"; exit 1; }
REF="$(plugin_copy)"; cp "$FACTORY_DIR/test/fixtures/gate.bash.sh" "$REF/scripts/gate.sh"
refgate() { bash "$REF/scripts/gate.sh" "$@"; }
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
pygate --help >/dev/null 2>&1 || { fail "AC-8 the Python gate is missing: 'sf.py gate --help' fails, so test-plan, weight and the usage cannot be checked"; exit 1; }

run() {  # run <gate args...>: OUT, ERR, CODE of the Python gate
  OUT="$(pygate "$@" 2>"$T/err")"; CODE=$?; ERR="$(cat "$T/err")"
  case "$ERR" in "usage: sf.py"*) fail "AC-8 sf.py has no gate command"; return 1 ;; esac
}
exact() {  # exact <label> <exit wanted> <exact stderr wanted> <gate args...>
  local label="$1" want="$2" msg="$3"; shift 3
  run "$@" || return
  if [ "$CODE" = "$want" ] && [ "$ERR" = "$msg" ]; then pass "AC-8 $label"
  else fail "AC-8 $label: exit $CODE (want $want), stderr '$ERR' (want '$msg')"; fi
}
like_ref() {  # like_ref <label> <gate args...>: code, stdout and stderr equal the Bash gate's, in en and pt-BR
  local label="$1" lang; shift
  for lang in en pt-BR; do
    FACTORY_LANGUAGE=$lang refgate "$@" >"$T/ro" 2>"$T/re"; rc=$?
    FACTORY_LANGUAGE=$lang pygate "$@" >"$T/po" 2>"$T/pe"; pc=$?
    if [ "$rc" = "$pc" ] && cmp -s "$T/ro" "$T/po" && cmp -s "$T/re" "$T/pe"; then pass "AC-8 $label ($lang) is as the Bash gate says it"
    else fail "AC-8 $label ($lang): python exit $pc stderr '$(head -c 400 "$T/pe")' vs bash exit $rc stderr '$(head -c 400 "$T/re")'"; fi
  done
}

r="$(new_repo)"; cd "$r"

# ---- weight
spec() {  # spec <header lines...>
  { printf '# x - spec\n\n**Issue:** #7\n'; printf '%s\n' "$@"; printf '\n## Product\n**Acceptance criteria**\n- **AC-1** - Given a, when b, then c\n\n## Decisions\n- **Weight:** heavy was discussed, standard kept\n'; } > spec.md
}
for w in light standard heavy; do spec "**Weight:** $w"; exact "weight $w passes" 0 "gate weight: pass" weight spec.md; done
spec '**Weight:** `heavy`'; exact "a backticked weight passes" 0 "gate weight: pass" weight spec.md
spec $'**Weight:** light\r'; exact "a CRLF line is stripped of its \\r and passes" 0 "gate weight: pass" weight spec.md
printf '**Weight:** standard\r\n\r\n## Product\r\n' > spec.md; exact "a whole CRLF spec passes" 0 "gate weight: pass" weight spec.md
spec; exact "no weight line (the one in Decisions is not the header's)" 1 "weight: the spec header has no '**Weight:** light|standard|heavy' line (spec.md)
gate weight: FAIL (exit 1)" weight spec.md
spec "**Weight:** light" "**Weight:** heavy"; exact "two weight lines" 1 "weight: the spec header has more than one weight line:
**Weight:** light
**Weight:** heavy
gate weight: FAIL (exit 1)" weight spec.md
spec "**Weight:** medium"; exact "an unknown weight" 1 "weight: '**Weight:** medium' names no weight the factory knows (light, standard, heavy)
gate weight: FAIL (exit 1)" weight spec.md
spec $'**Weight:** medium\r'; run weight spec.md
case "$ERR" in *$'\r'*) fail "AC-8 a \\r leaked into the weight message: $ERR" ;; *"'**Weight:** medium' names no weight"*) pass "AC-8 the \\r is stripped from the weight message" ;; *) fail "AC-8 weight with \\r: $ERR" ;; esac
for bad in "light | standard | heavy" "Heavy" "" "heavy, light"; do spec "**Weight:** $bad"; like_ref "weight '$bad'" weight spec.md; done
exact "weight with a missing spec is exit 2" 2 "weight: spec 'missing.md' not found
gate weight: FAIL (exit 2)" weight missing.md
exact "weight without an argument is exit 2" 2 "weight: spec '' not found
gate weight: FAIL (exit 2)" weight
# no config query: a config the queries could not read does not stop weight
spec "**Weight:** light"
( export FACTORY_CONFIG="$T/not-there.yml"; run weight spec.md; [ "$CODE" = 0 ] && [ "$ERR" = "gate weight: pass" ] && pass "AC-8 weight asks the config nothing: it passes with a config file that is not there" || fail "AC-8 weight with no config file: exit $CODE, $ERR" )
BROKEN="$T/broken.yml"; printf 'layers: [this is not\n' > "$BROKEN"
( export FACTORY_CONFIG="$BROKEN"; run weight spec.md; [ "$CODE" = 0 ] && pass "AC-8 weight passes with a config the queries could not parse" || fail "AC-8 weight with a broken config: exit $CODE, $ERR" )

# ---- test-plan
plan() {  # plan <rows...>: a spec with AC-1 and AC-2 and these table rows
  {
    printf '# x - spec\n\n## Product\n**Acceptance criteria**\n- **AC-1** - Given a, when b, then c\n- **AC-2** - Given d, when e, then f\n\n## Architecture\nx\n\n## Test plan\n_Tech Lead_\n\n| AC | Layer | Test file |\n|---|---|---|\n'
    printf '%s\n' "$@"; printf '\n## Security\nn/a\n'
  } > spec.md
}
plan '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B.kt` |'
exact "a complete plan passes" 0 "gate test-plan: pass" test-plan spec.md
plan '| AC-1 | api | `api/src/test/A.kt` |'
exact "an AC with no row" 1 "test-plan: the pipeline cannot run these acceptance tests (paths are repo-relative):
AC-2: no row in '## Test plan'
gate test-plan: FAIL (exit 1)" test-plan spec.md
plan '| AC-1 | api | `web/a.test.ts` |' '| AC-2 | nope | `x` |'
run test-plan spec.md
[ "$CODE" = 1 ] && pass "AC-8 a wrong path and an unknown layer block" || fail "AC-8 wrong path: exit $CODE"
case "$ERR" in *$'\n AC-1 : \'web/a.test.ts\' is not a test file of layer \'api\' (its tests: api/src/test/**)\n'*) pass "AC-8 the wrong path message lists the layer's tests" ;; *) fail "AC-8 wrong path message: $ERR" ;; esac
case "$ERR" in *$'\n AC-2 : unknown layer \'nope\' (layers: api web e2e, or manual)\n'*) pass "AC-8 the unknown layer message lists the layers" ;; *) fail "AC-8 unknown layer message: $ERR" ;; esac
plan '| AC-1 | manual | n/a |' '| AC-2 | e2e | `web/e2e/a.spec.ts` |'
exact "a manual layer is checked by hand" 0 "gate test-plan: pass" test-plan spec.md
plan '| AC-1, AC-2 | e2e | `web/e2e/a.spec.ts` |'
exact "two ACs in one row" 0 "gate test-plan: pass" test-plan spec.md
plan '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | |'
exact "a row with no path" 1 "test-plan: the pipeline cannot run these acceptance tests (paths are repo-relative):
 AC-2 : 'no path' is not a test file of layer 'api' (its tests: api/src/test/**)
gate test-plan: FAIL (exit 1)" test-plan spec.md
plan '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B.kt` (a|b) |'
exact "a | in a cell after the file cell does not change the answer" 0 "gate test-plan: pass" test-plan spec.md
plan '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B|C.kt` |'
run test-plan spec.md
[ "$CODE" = 1 ] && case "$ERR" in *"AC-2: 'api/src/test/B' is not a test file"*|*"is not a test file of layer 'api'"*) pass "AC-8 a | inside the path splits the cell: blocked" ;; *) fail "AC-8 | in path: $ERR" ;; esac || fail "AC-8 | in path: exit $CODE"
printf '# x\n\n## Product\n- **AC-1** - a\n\n## Test plan\n\nnone\n' > spec.md
exact "a Test plan with no rows" 1 "test-plan: '## Test plan' has no rows in spec.md
gate test-plan: FAIL (exit 1)" test-plan spec.md
exact "test-plan with a missing spec is exit 2" 2 "test-plan: spec 'nothing.md' not found
gate test-plan: FAIL (exit 2)" test-plan nothing.md
exact "test-plan without an argument is exit 2" 2 "test-plan: spec '' not found
gate test-plan: FAIL (exit 2)" test-plan
# the spec of this very card, and a matrix of shapes, byte for byte against the Bash gate
like_ref "this card's own spec" test-plan "$FACTORY_DIR/../docs/superpowers/specs/2026-10-14-py-12-port-gate-sh-to-python-the-static-design.md"
plan '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `api/src/test/B.kt` (a\|b) | a\|b |'; like_ref "an escaped | in a cell" test-plan spec.md
plan '| AC-1 | web | `web/lib/a.test.ts` |' '| AC-2 | e2e | `web/e2e/x.spec.ts` |'; like_ref "web and e2e rows" test-plan spec.md
plan '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | web | `api/src/test/B.kt` |' '| AC-3 | api | `x` |'; like_ref "a row for an AC that is not in the Product" test-plan spec.md
plan '|AC-1|api|`api/src/test/A.kt`|' '|AC-2|api|`api/src/test/B.kt`|'; like_ref "rows with no spaces" test-plan spec.md
plan '| AC-1 | api | `api/src/test/A.kt` and `api/src/main/B.kt` |' '| AC-2 | api | `api/src/test/B.kt` |'; like_ref "two paths in one cell: the first counts" test-plan spec.md
printf '# x\r\n\r\n## Product\r\n- **AC-1** - a\r\n\r\n## Test plan\r\n\r\n| AC | Layer | Test file |\r\n|---|---|---|\r\n| AC-1 | api | `api/src/test/A.kt` |\r\n' > spec.md; like_ref "a CRLF spec" test-plan spec.md

# ---- the usage text
run --help
[ "$CODE" = 0 ] && [ -z "$ERR" ] && pass "AC-8 --help exits 0 with nothing on stderr" || fail "AC-8 --help: exit $CODE, stderr '$ERR'"
helpout="$OUT"
[ "$helpout" = "$(refgate --help 2>/dev/null)" ] && pass "AC-8 --help prints the Bash gate's usage byte for byte" || fail "AC-8 --help differs from the Bash usage"
case "$helpout" in *"  green <layer> <selector>                 the tests ran and pass (reuses a pass recorded on this commit)"*) pass "AC-8 the usage lists green <layer> <selector>" ;; *) fail "AC-8 the usage has no green line: $helpout" ;; esac
case "$helpout" in *"  weight <spec>                            the spec's header names one weight: light, standard or heavy"*) pass "AC-8 the usage lists weight <spec>" ;; *) fail "AC-8 the usage has no weight line" ;; esac
case "$helpout" in "usage: gate.sh [-C <worktree>] <gate> ..."*"In a factory run (SHIPFLOOR_RUN_LOCK), the verdict is also written to <lock>/last-gate for the dispatcher.") pass "AC-8 the usage starts and ends as it does today" ;; *) fail "AC-8 usage frame: $helpout" ;; esac
for a in help -h; do run $a; [ "$OUT" = "$helpout" ] && [ "$CODE" = 0 ] && pass "AC-8 '$a' is --help" || fail "AC-8 '$a': exit $CODE"; done
run
[ "$CODE" = 2 ] && [ "$ERR" = "$helpout" ] && [ -z "$OUT" ] && pass "AC-8 no argument prints the same usage on stderr, exit 2" || fail "AC-8 no argument: exit $CODE"
run bogus
[ "$CODE" = 2 ] && [ "$ERR" = "$helpout
gate bogus: FAIL (exit 2)" ] && pass "AC-8 an unknown command prints the usage and the verdict" || fail "AC-8 unknown command: exit $CODE, stderr '$ERR'"
finish
