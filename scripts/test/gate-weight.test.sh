#!/usr/bin/env bash
# #133 AC-1: a spec leaves Refine with one weight (light, standard or heavy) in its header; the weight gate refuses
# a spec with none, two or another value. Every gate also leaves its verdict in the run's lock for the dispatcher.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
AC="AC-1"

spec() {  # spec <header lines...>: a spec with these lines after the title and a body that mentions a weight line too
  { printf '# x — spec\n\n**Issue:** #7 · **Branch:** `feat/7-x` · **Date:** 2026-10-12\n**Roles:** PO, Tech Lead\n'
    printf '%s\n' "$@"
    printf '\n## Product\n**Acceptance criteria**\n- **AC-1** — Given a, when b, then c\n\n## Decisions\n- **Weight:** heavy was discussed, standard kept\n'
  } > spec.md
}

r="$(new_repo)"; cd "$r"
for w in light standard heavy; do
  spec "**Weight:** $w"
  assert_exit 0 bash "$GATE" weight spec.md
done
spec '**Weight:** `heavy`'
assert_exit 0 bash "$GATE" weight spec.md
spec $'**Weight:** light\r'
assert_exit 0 bash "$GATE" weight spec.md

# none: the line in ## Decisions is not the header's
spec
assert_exit 1 bash "$GATE" weight spec.md
out="$(bash "$GATE" weight spec.md 2>&1)"
assert_contains "$out" "no '**Weight:** light|standard|heavy' line"
assert_contains "$out" "gate weight: FAIL (exit 1)"
# two, or a value the factory does not know
spec "**Weight:** light" "**Weight:** heavy"
assert_exit 1 bash "$GATE" weight spec.md
assert_contains "$(bash "$GATE" weight spec.md 2>&1)" "more than one weight line"
for bad in medium "light | standard | heavy" "Heavy" "" "heavy, light"; do
  spec "**Weight:** $bad"
  assert_exit 1 bash "$GATE" weight spec.md
done
assert_contains "$(spec '**Weight:** medium'; bash "$GATE" weight spec.md 2>&1)" "names no weight the factory knows (light, standard, heavy)"
# no spec is bad usage, never a pass
assert_exit 2 bash "$GATE" weight missing.md
assert_exit 2 bash "$GATE" weight

# the template carries the line, and the refine skill sets it and runs the gate before the commit
tpl="$(cat "$FACTORY_DIR/../templates/spec-template.md")"
case "$tpl" in *$'**Roles:**'*$'\n**Weight:** light | standard | heavy\n'*$'\n## Product'*) pass "AC-1 the template's header has the weight line" ;; *) fail "AC-1 the template has no **Weight:** header line" ;; esac
skill="$(cat "$FACTORY_DIR/../skills/refine/SKILL.md")"
case "$skill" in *"gate.sh -C <worktree> weight <spec>"*"git add <spec> && git commit"*) pass "AC-1 refine runs the weight gate before the spec commit" ;; *) fail "AC-1 the refine skill does not run 'gate.sh -C <worktree> weight <spec>' before its commit" ;; esac
case "$skill" in *'`heavy` when'*'`light` when'*'`standard` otherwise'*) pass "AC-1 the skill says how Refine picks the weight" ;; *) fail "AC-1 the skill has no rule for light, standard and heavy" ;; esac
case "$(bash "$GATE" --help)" in *"weight <spec>"*) pass "AC-1 gate.sh --help lists the weight gate" ;; *) fail "AC-1 gate.sh --help does not list weight" ;; esac

# the verdict a gate leaves for the dispatcher: <lock>/last-gate, overwritten by each gate of the run
lock="$(mktemp -d)"
spec "**Weight:** light"
SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" weight spec.md 2>/dev/null
[ "$(cat "$lock/last-gate" 2>/dev/null)" = $'weight\tpass' ] && pass "AC-1 a pass is written to the run's lock" || fail "AC-1 last-gate after a pass is '$(cat "$lock/last-gate" 2>/dev/null)'"
spec
SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" weight spec.md 2>/dev/null; rc=$?
[ "$rc" = 1 ] && pass "AC-1 the lock does not change the exit code" || fail "AC-1 exit $rc with a run lock, want 1"
[ "$(cat "$lock/last-gate" 2>/dev/null)" = $'weight\tFAIL' ] && pass "AC-1 a failure overwrites it" || fail "AC-1 last-gate after a failure is '$(cat "$lock/last-gate" 2>/dev/null)'"
SHIPFLOOR_RUN_LOCK="$lock/gone" bash "$GATE" weight spec.md 2>/dev/null
[ ! -e "$lock/gone" ] && pass "AC-1 a lock that is not a directory gets nothing" || fail "AC-1 the gate created $lock/gone"
rm -f "$lock/last-gate"; bash "$GATE" weight spec.md 2>/dev/null
[ ! -e "$lock/last-gate" ] && pass "AC-1 outside a run nothing is written" || fail "AC-1 a gate outside a run wrote last-gate"
finish
