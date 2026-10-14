#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
export FACTORY_HOME="$(mktemp -d)"
remote="$(mktemp -d)"; git init -q --bare "$remote"
r="$(new_repo)"; cd "$r"; git remote add origin "$remote"; git push -q origin main
export FACTORY_REPO="$r"
j="$(mktemp)"; m="$(mktemp)"
echo '{"issue":26,"slug":"rl","pipeline":"refine","outcome":"ok","agents":[{"role":"product-owner","tokens":1000,"duration_s":60}],"rounds":{},"gates_failed":[],"manual_edit":null,"started_at":"2026-10-09T10:00:00-03:00","finished_at":"2026-10-09T10:12:00-03:00"}' > "$j"
echo '# Relatório' > "$m"
assert_exit 0 bash "$FACTORY_DIR/report.sh" 26 rl refine "$j" "$m"
files="$(git --git-dir="$remote" ls-tree -r --name-only factory-reports)"
assert_contains "$files" "reports/26-rl/refine-"
assert_contains "$files" ".json"
assert_contains "$(git --git-dir="$remote" log --format=%s factory-reports)" "26"
[ "$(git --git-dir="$remote" rev-list --count main)" = "1" ] && pass "main untouched" || fail "main changed"
assert_exit 0 bash "$FACTORY_DIR/report.sh" 26 rl develop "$j" "$m"
assert_contains "$(git --git-dir="$remote" ls-tree -r --name-only factory-reports)" "develop-"
out="$(bash "$FACTORY_DIR/metrics.sh")"
assert_contains "$out" $'26\trefine\tok\t1000\t12'

# ---- #161 (PY-08): pins what report.sh does today, odd results included.
rep() {  # rep <home> <repo> <issue> <slug> <pipeline> <json>: one report.sh run, with its own home and repository
  FACTORY_HOME="$1" FACTORY_REPO="$2" bash "$FACTORY_DIR/report.sh" "$3" "$4" "$5" "$6" "$m"
}

# AC-3 the remote factory-reports branch exists and this home has no local worktree: report.sh starts one from
# origin/factory-reports with -B, so a stale local branch of that name is reset to the remote one, not an error
h3="$(mktemp -d)"; r3="$(new_repo)"; git -C "$r3" remote add origin "$remote"
git -C "$r3" branch factory-reports main   # a stale local branch of the same name, pointing elsewhere
stale="$(git -C "$r3" rev-parse factory-reports)"
[ ! -e "$h3/reports-wt" ] && pass "AC-3 precondition: no local worktree" || fail "AC-3 precondition: a worktree exists"
assert_exit 0 rep "$h3" "$r3" 27 two refine "$j"
[ -e "$h3/reports-wt/.git" ] && pass "AC-3 the worktree is created in the home" || fail "AC-3 no worktree in $h3"
[ "$(git -C "$h3/reports-wt" rev-parse --abbrev-ref HEAD)" = factory-reports ] && pass "AC-3 the worktree is on factory-reports" || fail "AC-3 worktree branch: $(git -C "$h3/reports-wt" rev-parse --abbrev-ref HEAD)"
[ "$(git -C "$r3" rev-parse factory-reports)" != "$stale" ] && pass "AC-3 -B moved the stale local branch" || fail "AC-3 the stale local branch was not reset"
[ "$(git -C "$r3" rev-parse factory-reports)" = "$(git --git-dir="$remote" rev-parse factory-reports)" ] && pass "AC-3 the local branch equals the remote one after the push" || fail "AC-3 local and remote factory-reports differ"
files="$(git --git-dir="$remote" ls-tree -r --name-only factory-reports)"
assert_contains "$files" "reports/26-rl/refine-"   # the reports already on the remote branch are kept
assert_contains "$files" "reports/27-two/refine-"  # and the new one is on top of them
[ "$(git --git-dir="$remote" log --format=%s factory-reports | grep -c 'start reports branch')" = 1 ] && pass "AC-3 history continues the remote branch (one root commit)" || fail "AC-3 the remote branch was started again"

# AC-3 the push fails: report.sh exits 1, the report stays committed in the local worktree, the remote has nothing
remote_f="$(mktemp -d)"; git init -q --bare "$remote_f"
printf '#!/bin/sh\nexit 1\n' > "$remote_f/hooks/pre-receive"; chmod +x "$remote_f/hooks/pre-receive"
rf="$(new_repo)"; git -C "$rf" remote add origin "$remote_f"; hf="$(mktemp -d)"
assert_exit 1 rep "$hf" "$rf" 28 three develop "$j"
[ -z "$(git --git-dir="$remote_f" branch --list factory-reports)" ] && pass "AC-3 a failed push leaves no factory-reports on the remote" || fail "AC-3 the remote got the branch"
assert_contains "$(git -C "$hf/reports-wt" log --format=%s -1)" "chore(factory): report #28 develop"
assert_contains "$(git -C "$hf/reports-wt" ls-tree -r --name-only HEAD)" "reports/28-three/develop-"

# AC-3 two reports in the same second (the clock is fixed: the name is <pipeline>-<second>): the second one overwrites the
# first in the tree, as today, and an identical one has nothing to commit, so report.sh fails
fixed="$(mktemp -d)"; printf '#!/bin/sh\necho 2026-10-14T120000\n' > "$fixed/date"; chmod +x "$fixed/date"
remote_s="$(mktemp -d)"; git init -q --bare "$remote_s"
rs="$(new_repo)"; git -C "$rs" remote add origin "$remote_s"; hs="$(mktemp -d)"
j2="$(mktemp)"; sed 's/"tokens":1000/"tokens":2000/' "$j" > "$j2"
assert_exit 0 env PATH="$fixed:$PATH" FACTORY_HOME="$hs" FACTORY_REPO="$rs" bash "$FACTORY_DIR/report.sh" 29 same refine "$j" "$m"
assert_exit 0 env PATH="$fixed:$PATH" FACTORY_HOME="$hs" FACTORY_REPO="$rs" bash "$FACTORY_DIR/report.sh" 29 same refine "$j2" "$m"
[ "$(git --git-dir="$remote_s" ls-tree -r --name-only factory-reports | grep -c 'reports/29-same/refine-')" = 2 ] && pass "AC-3 two reports in one second leave one json and one md (the same name)" || fail "AC-3 same-second files: $(git --git-dir="$remote_s" ls-tree -r --name-only factory-reports)"
assert_contains "$(git --git-dir="$remote_s" show factory-reports:reports/29-same/refine-2026-10-14T120000.json)" '"tokens":2000'
case "$(git --git-dir="$remote_s" show factory-reports:reports/29-same/refine-2026-10-14T120000.json)" in *'"tokens":1000'*) fail "AC-3 the first same-second report survived in the tree" ;; *) pass "AC-3 the second same-second report replaced the first in the tree" ;; esac
[ "$(git --git-dir="$remote_s" log --format=%s factory-reports | grep -c 'report #29')" = 2 ] && pass "AC-3 both same-second reports are commits (the first stays in history)" || fail "AC-3 same-second commits"
assert_exit 1 env PATH="$fixed:$PATH" FACTORY_HOME="$hs" FACTORY_REPO="$rs" bash "$FACTORY_DIR/report.sh" 29 same refine "$j2" "$m"

# AC-3 the header comment (report.sh lines 3-4) is the report.json schema the skills point to
hdr="$(sed -n '3,4p' "$FACTORY_DIR/report.sh")"
case "$hdr" in "# report.json schema: {"*) pass "AC-3 line 3 opens the report.json schema" ;; *) fail "AC-3 line 3 is not the schema: $hdr" ;; esac
for k in issue slug pipeline started_at finished_at outcome agents role tokens duration_s rounds gates_failed flaky gates_reused manual_edit; do
  assert_contains "$hdr" "\"$k\""
done
assert_contains "$hdr" '"outcome":"ok|blocked|infra"'
assert_contains "$(sed -n '4p' "$FACTORY_DIR/report.sh")" '"agents":[{"role","tokens","duration_s"}]'
finish
