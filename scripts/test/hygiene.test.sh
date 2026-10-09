#!/usr/bin/env bash
# Nothing the plugin ships names its first project, its owner or one machine's paths.
source "$(dirname "$0")/lib.sh"
root="$FACTORY_DIR/.."
hits="$(cd "$root" && grep -rIniE 'pickio|kennedykjj|/c/Users|scripts/factory|PICKIO_FACTORY' \
  skills agents scripts templates installer examples README.md .claude-plugin 2>/dev/null | grep -v '^scripts/test/' || true)"
[ -z "$hits" ] && pass "no project- or machine-specific references" || fail "found:
$hits"
for a in backend-engineer frontend-engineer; do
  [ ! -e "$root/agents/$a.md" ] && pass "no $a agent in the plugin" || fail "agents/$a.md still shipped"
done
[ -f "$root/skills/validar/SKILL.md" ] && pass "validar stage" || fail "skills/validar missing"
[ -f "$root/agents/engineer.md" ] && pass "generic engineer agent" || fail "agents/engineer.md missing"
[ -f "$root/examples/factory.yml" ] && pass "example config" || fail "examples/factory.yml missing"
assert_exit 0 env FACTORY_CONFIG="$root/examples/factory.yml" bash "$FACTORY_DIR/mylos-config.sh" validate
finish
