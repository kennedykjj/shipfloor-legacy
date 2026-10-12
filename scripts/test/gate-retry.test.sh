#!/usr/bin/env bash
# A layer with retry: 1 runs a failed selector once more in green, and a failed build once more; red never retries.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
cfg="$(mktemp)"; sed "s/^\(    ran: 'Tests +\[1-9\]\[0-9\]\* passed'\)$/\1\n    retry: 1/" "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
grep -q 'retry: 1' "$cfg" && pass "fixture layer gets retry: 1" || fail "could not add retry to the fixture"
bin="$(mktemp -d)"
cat > "$bin/pnpm" <<EOF
#!/usr/bin/env bash
if [ -e "$bin/once" ]; then echo " Tests  1 passed (1)"; exit 0; fi
touch "$bin/once"; echo "AssertionError: expected 1 to be 2"; echo " Tests  1 failed (1)"; exit 1
EOF
chmod +x "$bin/pnpm"
r="$(new_repo)"; cd "$r"; mkdir -p web
out="$(env FACTORY_CONFIG="$cfg" FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web web/a.test.ts 2>&1)"; code=$?
[ "$code" = 0 ] && pass "a test that passes on the retry passes green" || fail "retry did not pass: $out"
assert_contains "$out" "flaky: web web/a.test.ts"
rm -f "$bin/once"
assert_exit 0 env FACTORY_CONFIG="$cfg" FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web web/a.test.ts
# build: the same layer's build that fails once and then passes is flaky, not blocked; without retry it blocks
rm -f "$bin/once"; echo x > web/a.ts; base="$(git rev-parse HEAD)"
out="$(env FACTORY_CONFIG="$cfg" FACTORY_PNPM="$bin/pnpm" bash "$GATE" build "$base" 2>&1)"; code=$?
[ "$code" = 0 ] && pass "a build that passes on the retry passes" || fail "build retry did not pass: $out"
assert_contains "$out" "flaky: web build"
rm -f "$bin/once"
assert_exit 1 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" build "$base"
finish
