#!/usr/bin/env bash
# deploy.sh approval, what GitHub must show: an open PR, every required check reported.
source "$(dirname "$0")/deploy-lib.sh"

# no open PR while the worktree exists → blocked with a comment (not a crash)
setup; mkdir -p "$FACTORY_WT_ROOT"; git -C "$repo" worktree add -q "$FACTORY_WT_ROOT/7" feat/7-x; touch "$FG/no-pr"
code="$(run 7)"; [ "$code" = 5 ] && pass "missing PR → blocked" || fail "exit $code: $(cat "$T/out")"

# checks still pending keep waiting; a required check that never reports is not green
setup; printf 'deploy: {required_checks: [api, web]}\n' >> "$FACTORY_CONFIG"; sed -i '/healthcheck/d' "$FACTORY_CONFIG"
# (3 polls, not the 60 a test gets by default: the wait ends the same way)
code="$(FACTORY_POLLS=3 run 7)"; [ "$code" = 5 ] && pass "missing required check → not merged" || fail "exit $code: $(cat "$T/out")"
finish
