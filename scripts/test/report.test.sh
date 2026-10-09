#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
export FACTORY_HOME="$(mktemp -d)"
remote="$(mktemp -d)"; git init -q --bare "$remote"
r="$(new_repo)"; cd "$r"; git remote add origin "$remote"; git push -q origin main
export FACTORY_REPO="$r"
j="$(mktemp)"; m="$(mktemp)"
echo '{"issue":26,"slug":"rl","pipeline":"refinar","outcome":"ok","agents":[{"role":"product-owner","tokens":1000,"duration_s":60}],"rounds":{},"gates_failed":[],"manual_edit":null,"started_at":"2026-10-09T10:00:00-03:00","finished_at":"2026-10-09T10:12:00-03:00"}' > "$j"
echo '# Relatório' > "$m"
assert_exit 0 bash "$FACTORY_DIR/report.sh" 26 rl refinar "$j" "$m"
files="$(git --git-dir="$remote" ls-tree -r --name-only factory-reports)"
assert_contains "$files" "reports/26-rl/refinar-"
assert_contains "$files" ".json"
assert_contains "$(git --git-dir="$remote" log --format=%s factory-reports)" "26"
[ "$(git --git-dir="$remote" rev-list --count main)" = "1" ] && pass "main untouched" || fail "main changed"
assert_exit 0 bash "$FACTORY_DIR/report.sh" 26 rl desenvolver "$j" "$m"
assert_contains "$(git --git-dir="$remote" ls-tree -r --name-only factory-reports)" "desenvolver-"
out="$(bash "$FACTORY_DIR/metrics.sh")"
assert_contains "$out" $'26\trefinar\tok\t1000\t12'
finish
