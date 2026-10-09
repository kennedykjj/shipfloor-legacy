#!/usr/bin/env bash
# aghanim-config.sh reads, validates and answers queries about .aghanim/factory.yml.
source "$(dirname "$0")/lib.sh"
CFG="$FACTORY_DIR/aghanim-config.sh"
c() { bash "$CFG" "$@"; }
matches() {  # matches <regex> <path>: passes when the ERE matches the path
  if printf '%s\n' "$2" | grep -Eq -- "$1"; then pass "'$2' matches"; else fail "'$2' should match $1"; fi
}
misses() {
  if printf '%s\n' "$2" | grep -Eq -- "$1"; then fail "'$2' should not match $1"; else pass "'$2' does not match"; fi
}
bad_config() {  # bad_config <label> <yaml>: validate must refuse it
  local f; f="$(mktemp)"; printf '%s\n' "$2" > "$f"
  assert_exit 1 env FACTORY_CONFIG="$f" bash "$CFG" validate
}

assert_exit 0 c validate
[ "$(c get project.repo)" = "acme/shop" ] && pass "get project.repo" || fail "get project.repo: $(c get project.repo)"
[ "$(c get project.main)" = "main" ] && pass "project.main default" || fail "project.main: $(c get project.main)"
[ "$(c get limits.develop.wip)" = "4" ] && pass "limits default" || fail "limits: $(c get limits.develop.wip)"
[ "$(c get paths.specs)" = "docs/superpowers/specs/" ] && pass "paths default" || fail "paths: $(c get paths.specs)"
[ "$(c get context | tr '\n' ' ')" = "PRODUCT.md CLAUDE.md " ] && pass "list one per line" || fail "context: $(c get context)"
assert_exit 1 c get project.nothing
[ "$(c layers | tr '\n' ' ')" = "api web e2e " ] && pass "layers" || fail "layers: $(c layers)"
[ "$(c layers --implementers | tr '\n' ' ')" = "api web " ] && pass "implementers" || fail "implementers: $(c layers --implementers)"
[ "$(c layer api agent)" = "engineer" ] && pass "agent default" || fail "agent: $(c layer api agent)"
[ "$(c layer e2e needs_stack)" = "true" ] && pass "needs_stack" || fail "needs_stack: $(c layer e2e needs_stack)"
[ "$(c layer api path)" = "api/" ] && pass "layer path" || fail "path: $(c layer api path)"
assert_exit 2 c layer nope path
case "$(c get project.repo | od -c)" in *'\r'*) fail "CR in output" ;; *) pass "no CR in output" ;; esac

qa="$(c regex scope qa)"
matches "$qa" api/src/test/kotlin/ATest.kt; matches "$qa" web/lib/a.test.ts; matches "$qa" web/e2e/a.spec.ts
misses "$qa" web/lib/a.ts; misses "$qa" api/src/main/A.kt
matches "$(c regex scope web)" web/app/page.tsx; misses "$(c regex scope web)" api/A.kt
matches "$(c regex scope po)" docs/superpowers/specs/x.md; misses "$(c regex scope po)" docs/superpowers/plans/x.md
matches "$(c regex scope techlead)" docs/superpowers/plans/x.md
assert_exit 2 c regex scope e2e   # tests-only layers have no implementer
assert_exit 2 c regex scope nope
tc="$(c regex test-config)"; matches "$tc" web/vitest.config.ts; misses "$tc" web/vitest.config/x/y.ts
fb="$(c regex forbidden)"
for f in .aghanim/factory.yml .github/w.yml .claude/x.md CLAUDE.md api/.env web/.env.local docs/engineering/x.md; do matches "$fb" "$f"; done
misses "$fb" api/env.kt; misses "$fb" docs/CLAUDE.md.bak
matches "$(c regex migrations api)" api/src/main/resources/db/migration/V2__add.sql
misses "$(c regex migrations api)" api/src/main/resources/db/migration/sub/V2__add.sql
[ -z "$(c regex migrations web)" ] && pass "no migrations → empty" || fail "web migrations: $(c regex migrations web)"

[ "$(c layer-of web/e2e/x.spec.ts)" = "web" ] && pass "layer-of prefers the implementer" || fail "layer-of: $(c layer-of web/e2e/x.spec.ts)"
[ "$(c layer-of api/A.kt)" = "api" ] && pass "layer-of api" || fail "layer-of api"
assert_exit 1 c layer-of README.md

d="$(c describe)"; assert_contains "$d" "acme/shop"; assert_contains "$d" "api"; assert_contains "$d" "engineer"

# globs are literal outside * ? **
f="$(mktemp)"; cat > "$f" <<'EOF'
project: {name: x, repo: a/x}
board: {owner: a, number: 1}
layers:
  - {name: odd, path: 'my dir/', test: 't {selector}', ran: 'ok', tests: ['my dir/a+b(1).ts', 'pkg/?.ts']}
EOF
re="$(FACTORY_CONFIG="$f" c regex scope qa)"
matches "$re" 'my dir/a+b(1).ts'; misses "$re" 'my dirXa+b(1).ts'; misses "$re" 'my dir/aab1.ts'
matches "$re" pkg/a.ts; misses "$re" pkg/ab.ts; misses "$re" pkg/a/b.ts

bad_config "no layers" $'project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}'
bad_config "reserved name" $'project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n  - {name: qa, path: a/, test: t, ran: ok, tests: [a/**]}'
bad_config "bad regex" $'project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n  - {name: a, path: a/, test: t, ran: "(", tests: [a/**]}'
bad_config "tests_only with agent" $'project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n  - {name: a, path: a/, test: t, ran: ok, tests: [a/**], tests_only: true, agent: z}'
bad_config "duplicate name" $'project: {name: x, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n  - {name: a, path: a/, test: t, ran: ok, tests: [a/**]}\n  - {name: a, path: b/, test: t, ran: ok, tests: [b/**]}'
bad_config "bad slug" $'project: {name: X Y, repo: a/x}\nboard: {owner: a, number: 1}\nlayers:\n  - {name: a, path: a/, test: t, ran: ok, tests: [a/**]}'
bad_config "not yaml" $'project: [unclosed'
assert_exit 2 env FACTORY_CONFIG=/nonexistent/factory.yml bash "$CFG" get project.repo
# the stack block: commands are strings, ports a list of names used by url and health
stack_cfg() { local f; f="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$f"; printf '%s
' "$1" >> "$f"; echo "$f"; }
assert_exit 0 env FACTORY_CONFIG="$(stack_cfg 'stack: {url: "http://localhost:{web}", up: "x", down: "y", ports: [web, api], timeout: 60}')" bash "$CFG" validate
assert_exit 1 env FACTORY_CONFIG="$(stack_cfg 'stack: {url: "http://localhost:3000", ports: web}')" bash "$CFG" validate
assert_exit 1 env FACTORY_CONFIG="$(stack_cfg 'stack: {url: "http://localhost:{nope}", ports: [web]}')" bash "$CFG" validate
finish
