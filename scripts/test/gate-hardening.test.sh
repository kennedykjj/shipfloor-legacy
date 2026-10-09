#!/usr/bin/env bash
# Regression tests for the whole-branch review of the project-agnostic factory.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
CFG="$FACTORY_DIR/mylos-config.sh"
cfg_with() { local f; f="$(mktemp)"; printf '%s\n' "$1" > "$f"; echo "$f"; }
HEADER=$'project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}'
LAYER=$'layers:\n  - {name: app, path: app/, test: "echo ok", ran: ok, tests: ["app/**/*_test.go"]}'

# I1: an implementer may not touch a tests-only layer inside its path (fixtures, helpers, setup)
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p web/e2e/fixtures web/lib
echo x > web/e2e/fixtures/expect.ts
assert_exit 1 bash "$GATE" scope web "$base"
rm -rf web/e2e; echo x > web/lib/a.test.ts; echo x > web/lib/a.ts
assert_exit 0 bash "$GATE" scope web "$base"   # its own unit tests stay allowed

# I2: quoted or control-character file names never slip past forbidden/scope
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
blob="$(echo x | git hash-object -w --stdin)"
git -c core.protectNTFS=false update-index --add --cacheinfo 100644 "$blob" '.github/workflows/a"b.yml'
git -c core.protectNTFS=false commit -qm sneaky
assert_exit 1 bash "$GATE" forbidden "$base"
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
blob="$(echo x | git hash-object -w --stdin)"
git -c core.protectNTFS=false update-index --add --cacheinfo 100644 "$blob" $'app/a\nb.go'
git -c core.protectNTFS=false commit -qm newline
assert_exit 1 env FACTORY_CONFIG="$(cfg_with "$HEADER"$'\n'"${LAYER/app\//./}")" bash "$GATE" scope app "$base"

# I4: paths.specs must be a real directory prefix; an empty allow-list is never a pass
assert_exit 1 env FACTORY_CONFIG="$(cfg_with "$HEADER"$'\npaths: {specs: }\n'"$LAYER")" bash "$CFG" validate
assert_exit 1 env FACTORY_CONFIG="$(cfg_with "$HEADER"$'\npaths: {plans: docs/plans}\n'"$LAYER")" bash "$CFG" validate

# I5: wrong shapes are invalid (never a crash), and crashes are exit 2
for extra in 'stack: http://localhost:3000' 'deploy: CI' 'paths: docs/' 'review_criteria: [a]' \
             'limits: {refinar: 3}' 'context: PRODUCT.md'; do
  assert_exit 1 env FACTORY_CONFIG="$(cfg_with "$HEADER"$'\n'"$extra"$'\n'"$LAYER")" bash "$CFG" validate
done
assert_exit 1 env FACTORY_CONFIG="$(cfg_with "$HEADER"$'\nlayers:\n  - {name: a, path: 3, test: t, ran: ok, tests: [a/**]}')" bash "$CFG" validate
assert_exit 1 env FACTORY_CONFIG="$(cfg_with "$HEADER"$'\nlayers:\n  - {name: a, path: a/, test: t, ran: ok, tests: [a/**], migrations: {glob: "a/*.sql", comment: 3}}')" bash "$CFG" validate

# I6: patterns must be valid for grep -E (what the gates run), and PCRE-only syntax is refused
for p in '[[:foo:]]' '\\d+ passed' '(?i)ok'; do
  assert_exit 1 env FACTORY_CONFIG="$(cfg_with "$HEADER"$'\nlayers:\n  - {name: a, path: a/, test: t, ran: "'"$p"'", tests: [a/**]}')" bash "$CFG" validate
done
f="$(cfg_with "$HEADER"$'\nlayers:\n  - {name: a, path: a/, test: "echo boom; exit 1", ran: ok, setup_errors: "[[:foo:]]", tests: [a/**]}')"
r="$(new_repo)"; cd "$r"; mkdir -p a
assert_exit 2 env FACTORY_CONFIG="$f" bash "$GATE" red a x

# layer-of takes repo-relative paths, with or without ./
[ "$(bash "$CFG" layer-of ./web/a.ts)" = "web" ] && pass "layer-of strips ./" || fail "layer-of ./web/a.ts: $(bash "$CFG" layer-of ./web/a.ts)"
finish
