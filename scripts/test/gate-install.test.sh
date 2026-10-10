#!/usr/bin/env bash
# A layer's `install` runs before the gates that run its tests or build: once per content of the layer's
# directory, with no agent involved; a failing install is infrastructure (exit 3), not a test verdict.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
bin="$(mktemp -d)"
cfg="$(mktemp)"; sed "s|^\(    ran: 'Tests +\[1-9\]\[0-9\]\* passed'\)$|\1\n    install: 'bash \"$bin/install\"'|" "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
grep -q 'install:' "$cfg" && pass "fixture layer gets install" || fail "could not add install to the fixture"
printf '#!/usr/bin/env bash\necho ran >> "%s/installs"; [ ! -e "%s/broken" ]\n' "$bin" "$bin" > "$bin/install"
printf '#!/usr/bin/env bash\n[ -s "%s/installs" ] || { echo "pnpm: command not found"; exit 127; }\necho " Tests  1 passed (1)"\n' "$bin" > "$bin/pnpm"
chmod +x "$bin/install" "$bin/pnpm"
green() { env FACTORY_CONFIG="$cfg" FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web web/a.test.ts; }

r="$(new_repo)"; cd "$r"; mkdir -p web; echo a > web/a.test.ts; git add -A; git commit -qm web
assert_exit 0 green
assert_exit 0 green
[ "$(wc -l < "$bin/installs")" -eq 1 ] && pass "installed once for the same content" || fail "install ran $(wc -l < "$bin/installs") times"
echo b > web/package.json; git add -A; git commit -qm deps
assert_exit 0 green
[ "$(wc -l < "$bin/installs")" -eq 2 ] && pass "installed again after the layer changed" || fail "install ran $(wc -l < "$bin/installs") times"
[ -z "$(git status --porcelain)" ] && pass "the install marker stays out of the worktree" || fail "worktree dirty: $(git status --porcelain)"

# a failing install is infrastructure
touch "$bin/broken"; echo c > web/package.json; git commit -qam deps2
out="$(green 2>&1)"; code=$?
[ "$code" = 3 ] && pass "a failing install is exit 3" || fail "exit $code: $out"
assert_contains "$out" "install failed"
finish
