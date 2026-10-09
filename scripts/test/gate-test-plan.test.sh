#!/usr/bin/env bash
# test-plan: every AC has a row, and each row's test file is one its layer can run.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"

spec() {  # spec <test plan rows...>: a spec with AC-1 and AC-2 and these table rows
  {
    printf '# x — spec\n\n## Product\n**Acceptance criteria**\n- **AC-1** — Given a, when b, then c\n- **AC-2** — Given d, when e, then f\n\n## Architecture\nx\n\n## Test plan\n_Tech Lead_\n\n| AC | Layer | Test file |\n|---|---|---|\n'
    printf '%s\n' "$@"
    printf '\n## Security\nn/a\n'
  } > spec.md
}

r="$(new_repo)"; cd "$r"
spec '| AC-1 | api | `api/src/test/kotlin/AuthTest.kt` (wrong password → 400) |' \
     '| AC-2 | e2e | `web/e2e/login.spec.ts` |'
assert_exit 0 bash "$GATE" test-plan spec.md

# several ACs in one row, and a file per row
spec '| AC-1, AC-2 | web | `web/lib/auth.test.ts` |'
assert_exit 0 bash "$GATE" test-plan spec.md

# a manual row is allowed: checked by hand in review
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | manual | `docs/ci.md` (reviewed in the PR) |'
assert_exit 0 bash "$GATE" test-plan spec.md

# the test file belongs to no layer (the #40 case)
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | script | `scripts/security/selftest.sh` |'
assert_exit 1 bash "$GATE" test-plan spec.md
assert_contains "$(bash "$GATE" test-plan spec.md 2>&1)" "unknown layer 'script'"

spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `scripts/security/selftest.sh` |'
assert_exit 1 bash "$GATE" test-plan spec.md
assert_contains "$(bash "$GATE" test-plan spec.md 2>&1)" "scripts/security/selftest.sh"

# a file of another layer: green would run it with the wrong runner
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | web | `web/e2e/login.spec.ts` |'
assert_exit 1 bash "$GATE" test-plan spec.md

# no path, or an abbreviated one
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | AuthTest |'
assert_exit 1 bash "$GATE" test-plan spec.md
spec '| AC-1 | api | `api/src/test/A.kt` |' '| AC-2 | api | `.../AuthTest.kt` |'
assert_exit 1 bash "$GATE" test-plan spec.md

# an AC with no row
spec '| AC-1 | api | `api/src/test/A.kt` |'
assert_exit 1 bash "$GATE" test-plan spec.md
assert_contains "$(bash "$GATE" test-plan spec.md 2>&1)" "AC-2"

# empty table, missing section, missing file
spec
assert_exit 1 bash "$GATE" test-plan spec.md
printf '# x\n\n## Product\n- **AC-1** — x\n' > nosection.md
assert_exit 1 bash "$GATE" test-plan nosection.md
assert_exit 2 bash "$GATE" test-plan missing.md
assert_exit 2 bash "$GATE" test-plan

finish
