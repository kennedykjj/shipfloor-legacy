#!/usr/bin/env bash
# deploy.sh merging main into the PR when it cannot: a merge that fails with no conflicts, conflicts above
# deploy.conflict_max_files and above deploy.conflict_max_hunks. Exit code and what the fake gh recorded.
source "$(dirname "$0")/deploy-lib.sh"
want() { [ "$1" = "$2" ] && pass "$3" || fail "$3: exit $1, want $2: $(cat "$T/out")"; }
posted() { case "$(cat "$FG/calls" 2>/dev/null)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
dcfg() { sed -i '/^deploy:/d' "$FACTORY_CONFIG"; printf 'deploy: %s\n' "$1" >> "$FACTORY_CONFIG"; }
scene_two() { on_branch shared.txt card; on_branch lines.txt card; main_commit shared.txt main; main_commit lines.txt main; }  # two files, one hunk each
sent_back() {  # sent_back <label> <reason>: Coding, the reason on the card, nothing pushed or merged, worktree clean
  want "$code" 4 "$1 → back to Coding"
  [ "$(cat "$FG/status")" = Coding ] && pass "$1: card in Coding" || fail "status $(cat "$FG/status")"
  assert_contains "$(cat "$FG/comments")" "Back to Coding: $2"
  [ "$(git --git-dir="$remote" rev-parse feat/7-x)" = "$before" ] && pass "$1: nothing pushed" || fail "pushed a failed merge"
  [ ! -e "$FG/merged" ] && pass "$1: nothing merged" || fail "merged"
  [ ! -e "$FG/labels" ] && pass "$1: not labelled blocked" || fail "labelled"
  [ -z "$(git -C "$FACTORY_WT_ROOT/7" status --porcelain)" ] && pass "$1: worktree clean" || fail "worktree dirty"
  [ -z "$(git -C "$FACTORY_WT_ROOT/7" diff --name-only --diff-filter=U)" ] && pass "$1: no merge left in progress" || fail "unmerged files left"
}

# AC-3: a merge that fails without conflicts (a hook refuses the merge commit) → Coding with "merge failed: ..."
scene behind; printf '#!/bin/sh\necho "refused by hook" >&2\nexit 1\n' > "$repo/.git/hooks/pre-merge-commit"; chmod +x "$repo/.git/hooks/pre-merge-commit"
before="$(git --git-dir="$remote" rev-parse feat/7-x)"; code="$(run 7)"
sent_back "merge failing without conflicts" "merge failed: "
assert_contains "$(cat "$T/out")" "back to Coding: merge failed: "
[ ! -s "$FACTORY_HOME/tmp/7/resolve.files" ] && pass "no conflict handed over" || fail "handed over conflicts"
[ ! -e "$FACTORY_HOME/tmp/7/fix.findings" ] && pass "no fix round started" || fail "fix round started"

# conflicts in more files than deploy.conflict_max_files → Coding, with the count and the limit
scene two; dcfg '{conflict_max_files: 1}'; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; code="$(run 7)"
sent_back "2 conflicting files over limit 1" "2 files conflict with main (limit 1)"
[ ! -s "$FACTORY_HOME/tmp/7/resolve.files" ] && pass "files over the limit: nothing handed over" || fail "handed over"
# exactly at the limit is still handed to an agent (exit 3, not 4)
scene two; dcfg '{conflict_max_files: 2}'; code="$(run 7)"
want "$code" 3 "2 conflicting files at limit 2 → handed over"
assert_contains "$(cat "$T/out")" "CONFLICT lines.txt"
assert_contains "$(cat "$T/out")" "CONFLICT shared.txt"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "at the file limit: card stays in Ready for Prod" || fail "status $(cat "$FG/status")"
[ ! -e "$FG/labels" ] && pass "at the file limit: not labelled" || fail "labelled"

# conflicts in more hunks than deploy.conflict_max_hunks (files within their limit) → Coding
scene two; dcfg '{conflict_max_hunks: 1}'; before="$(git --git-dir="$remote" rev-parse feat/7-x)"; code="$(run 7)"
sent_back "2 conflict hunks over limit 1" "2 hunks conflict with main (limit 1)"
scene two; dcfg '{conflict_max_hunks: 2}'; code="$(run 7)"
want "$code" 3 "2 conflict hunks at limit 2 → handed over"
assert_contains "$(cat "$T/out")" "CONFLICT shared.txt"
[ "$(cat "$FG/status")" = "Ready for Prod" ] && pass "at the hunk limit: card stays in Ready for Prod" || fail "status $(cat "$FG/status")"
posted "pr merge" && fail "merged with conflicts handed over" || pass "at the hunk limit: nothing merged"
finish
