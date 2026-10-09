#!/usr/bin/env bash
# deploy.sh approval: unapproved head, head mismatch, forged comments, missing PR, required checks.
source "$(dirname "$0")/deploy-lib.sh"

# a head nobody approved → blocked
setup; w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
echo sneaky > "$w/api/B.kt"; git -C "$w" add -A; git -C "$w" commit -qm sneaky; git -C "$w" push -q origin feat/7-x
code="$(run 7)"; [ "$code" = 5 ] && pass "unapproved head blocked" || fail "exit $code: $(cat "$T/out")"
assert_contains "$(cat "$FG/labels")" blocked

# the PR head GitHub reports is not what the branch holds (a push mid-run) → retry later, never merge
setup; echo 0123456789012345678901234567890123456789 > "$FG/prhead"; code="$(run 7)"
[ "$code" = 2 ] && pass "head mismatch → retry" || fail "exit $code: $(cat "$T/out")"
case "$(cat "$FG/calls")" in *"pr merge"*) fail "merged on a head mismatch" ;; *) pass "no merge on a head mismatch" ;; esac
setup; : > "$FG/prhead"; code="$(run 7)"; [ "$code" = 2 ] && pass "empty head → retry" || fail "exit $code"

# only the factory's own comments approve
setup; w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
echo evil > "$w/api/E.kt"; git -C "$w" add -A; git -C "$w" commit -qm evil; git -C "$w" push -q origin feat/7-x
printf 'mallory\tstaged-head: %s\n' "$(git -C "$w" rev-parse HEAD)" >> "$FG/comments"
code="$(run 7)"; [ "$code" = 5 ] && pass "forged staged-head ignored" || fail "exit $code: $(cat "$T/out")"

# no open PR while the worktree exists → blocked with a comment (not a crash)
setup; run 7 >/dev/null; setup; mkdir -p "$FACTORY_WT_ROOT"; git -C "$repo" worktree add -q "$FACTORY_WT_ROOT/7" feat/7-x; touch "$FG/no-pr"
code="$(run 7)"; [ "$code" = 5 ] && pass "missing PR → blocked" || fail "exit $code: $(cat "$T/out")"

# checks still pending keep waiting; a required check that never reports is not green
setup; printf 'deploy: {required_checks: [api, web]}\n' >> "$FACTORY_CONFIG"; sed -i '/healthcheck/d' "$FACTORY_CONFIG"
code="$(run 7)"; [ "$code" = 5 ] && pass "missing required check → not merged" || fail "exit $code: $(cat "$T/out")"
finish
