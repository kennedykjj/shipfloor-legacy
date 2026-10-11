#!/usr/bin/env bash
# Gates follow the project's layers, whatever their names, paths and commands.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
export CALLS="$(mktemp)"
export FACTORY_CONFIG="$(mktemp)"
cat > "$FACTORY_CONFIG" <<'EOF'
project: {name: mono, repo: acme/mono}
board: {owner: acme, number: 1}
layers:
  - name: svc-a
    path: services/a/
    build: 'echo "svc-a $PWD" >> "$CALLS"'
    test: 'printf "%s\n" {selector} > "$CALLS.sel"; echo "--- FAIL: TestX"; exit 1'
    ran: '^ok '
    assertions: '--- FAIL'
    tests: ['services/a/**/*_test.go']
  - name: svc-b
    path: services/b/
    build: 'echo "svc-b $PWD" >> "$CALLS"'
    test: 'echo "ok  pkg 0.1s"'
    ran: '^ok '
    tests: ['services/b/**/*_test.go']
    migrations: {glob: 'services/b/migrations/*.sql', comment: '#'}
  - name: lib
    path: packages/lib/
    test: 'echo "no tests"'
    ran: '^ok '
    tests: ['packages/lib/test/**']
EOF
layout() { mkdir -p services/a services/b/migrations packages/lib; }

r="$(new_repo)"; cd "$r"; layout; base="$(git rev-parse HEAD)"; echo x > services/a/x.go
assert_exit 0 bash "$GATE" scope svc-a "$base"
assert_exit 1 bash "$GATE" scope svc-b "$base"
assert_exit 1 bash "$GATE" scope qa "$base"
echo x > services/b/y.go
assert_exit 1 bash "$GATE" scope svc-a "$base"
assert_exit 2 bash "$GATE" scope nope "$base"

r="$(new_repo)"; cd "$r"; layout; base="$(git rev-parse HEAD)"; mkdir -p services/a/pkg; echo x > services/a/pkg/x_test.go
assert_exit 0 bash "$GATE" scope qa "$base"
mkdir -p .shipfloor; echo x > .shipfloor/factory.yml
assert_exit 1 bash "$GATE" scope qa "$base"

# build runs only the changed layers, from the layer's directory
r="$(new_repo)"; cd "$r"; layout; base="$(git rev-parse HEAD)"; echo x > services/b/y.go; : > "$CALLS"
assert_exit 0 bash "$GATE" build "$base"
assert_contains "$(cat "$CALLS")" "svc-b"
assert_contains "$(cat "$CALLS")" "services/b"
case "$(cat "$CALLS")" in *svc-a*) fail "built an unchanged layer" ;; *) pass "unchanged layer not built" ;; esac

# red/green use the layer's runner; the selector is one argument, never shell code
r="$(new_repo)"; cd "$r"; layout
assert_exit 0 bash "$GATE" red svc-a 'a; touch PWNED'
[ "$(cat "$CALLS.sel")" = "a; touch PWNED" ] && pass "selector passed as one argument" || fail "selector: $(cat "$CALLS.sel")"
[ ! -e services/a/PWNED ] && [ ! -e PWNED ] && pass "selector not executed" || fail "selector ran as shell code"
assert_exit 0 bash "$GATE" green svc-b ./...
assert_exit 1 bash "$GATE" green lib x
assert_exit 2 bash "$GATE" green nope x
assert_exit 2 bash "$GATE" red nope x

# migrations of any layer, with the layer's comment prefix
r="$(new_repo)"; cd "$r"; layout; echo 'create table a (id int);' > services/b/migrations/1.sql; git add -A; git commit -qm m; base="$(git rev-parse HEAD)"
printf '# S\n\n## Rollback\n\nnão se aplica\n' > spec.md
printf '# we never drop here\ncreate table b (id int);\n' > services/b/migrations/2.sql
assert_exit 0 bash "$GATE" migration "$base" spec.md
echo 'drop table a;' > services/b/migrations/3.sql
assert_exit 1 bash "$GATE" migration "$base" spec.md
rm services/b/migrations/3.sql; echo 'create table a (id bigint);' > services/b/migrations/1.sql
assert_exit 1 bash "$GATE" migration "$base" spec.md

# no project → never a pass
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
assert_exit 2 env -u FACTORY_CONFIG SHIPFLOOR_HOME="$(mktemp -d)" bash "$GATE" scope qa "$base"
finish
