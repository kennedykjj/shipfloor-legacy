#!/usr/bin/env bash
# green/red must read runner output without ANSI colors.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
bin="$(mktemp -d)"
cat > "$bin/pnpm" <<'EOS'
#!/usr/bin/env bash
if [ -n "${NO_COLOR:-}" ]; then echo " Tests  4 passed (4)"; else printf ' \033[2mTests\033[22m  \033[1m\033[32m4 passed\033[39m\033[22m (4)\n'; fi
EOS
chmod +x "$bin/pnpm"
r="$(new_repo)"; cd "$r"; mkdir -p web
assert_exit 0 env -u NO_COLOR FACTORY_PNPM="$bin/pnpm" bash "$GATE" green web lib/a.test.ts
finish
