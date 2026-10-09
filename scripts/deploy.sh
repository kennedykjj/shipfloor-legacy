#!/usr/bin/env bash
# Deterministic deploy of one card (docs/superpowers/specs/2026-10-09-fast-safe-deploy-design.md).
# usage: deploy.sh <n> [--refresh | --continue]
#   --refresh   bring a Staged / Ready for Prod card's PR up to date with main (clean merges only); no merge to main
#   --continue  resume after the conflicts printed by a previous run were resolved and committed
# exit: 0 done · 3 conflicts to resolve · 4 sent back to Coding · 5 blocked · 6 failed after merge (reverted) · 2 usage
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/project.sh"

n="${1:-}"; mode="${2:-deploy}"
case "$mode" in deploy|--refresh|--continue) ;; *) n="" ;; esac
[[ "$n" =~ ^[0-9]+$ ]] || { echo "usage: deploy.sh <n> [--refresh | --continue]" >&2; exit 2; }
mylos_resolve . || exit 2
mapfile -d '' -t V < <(mylos_cfg values project.repo project.main deploy.ci_workflow deploy.environment \
  deploy.timeout_min deploy.conflict_max_files deploy.conflict_max_hunks paths.specs)
[ "${#V[@]}" -eq 8 ] || { echo "deploy: cannot read the project config" >&2; exit 2; }
REPO="${V[0]}" MAIN="${V[1]}" CI_WORKFLOW="${V[2]}" ENVIRONMENT="${V[3]}"
TIMEOUT_MIN="${V[4]:-30}" MAX_FILES="${V[5]:-5}" MAX_HUNKS="${V[6]:-20}" SPECS="${V[7]}"
HEALTH="$(mylos_cfg get deploy.healthcheck 2>/dev/null || true)"
GH="${FACTORY_GH:-gh}"; BOARD="${FACTORY_BOARD:-$HERE/board.sh}"; GATE="$HERE/gate.sh"
CURL="${FACTORY_CURL:-curl}"; POLL="${FACTORY_POLL:-30}"
WT="$FACTORY_WT_ROOT/$n"; TMP="$FACTORY_HOME/tmp/$n"; mkdir -p "$TMP"
TRAILER="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
START="$(date +%s)"

say() { echo "deploy #$n: $*"; }
g() { git -C "$WT" "$@"; }
comment() { "$GH" issue comment "$n" --repo "$REPO" --body "$1" >/dev/null; }
reset_worktree() {  # drop any merge in progress or local commit: back to the pushed branch
  [ -e "$WT/.git" ] || return 0
  g merge --abort >/dev/null 2>&1; g reset -q --hard "origin/$BRANCH" 2>/dev/null; g clean -qfd 2>/dev/null; return 0
}
block() {  # before merging: label, explain, stop
  reset_worktree
  comment "Factory deploy stopped: $1"
  "$GH" issue edit "$n" --repo "$REPO" --add-label blocked >/dev/null
  say "blocked: $1"; exit 5
}
back_to_coding() {
  reset_worktree
  comment "Back to Coding: $1"
  "$BOARD" move "$n" Coding >/dev/null || say "could not move the card to Coding"
  say "back to Coding: $1"; exit 4
}

# 1. card and PR
status="$("$BOARD" status "$n")" || { echo "deploy: cannot read the board" >&2; exit 2; }
if [ "$mode" = --refresh ]; then
  case "$status" in Staged|"Ready for Prod") ;; *) say "not staged ($status); nothing to refresh"; exit 0 ;; esac
elif [ "$status" != "Ready for Prod" ]; then
  echo "deploy: #$n is in '$status', not Ready for Prod" >&2; exit 2
fi
prs="$("$GH" pr list --repo "$REPO" --state open --base "$MAIN" --json number,headRefName --jq '.[] | "\(.number)\t\(.headRefName)"' \
  | grep -E $'\t'"(feat/$n-|revert/$n\$)" || true)"
[ "$(printf '%s' "$prs" | grep -c .)" -eq 1 ] || { [ "$mode" = --refresh ] && exit 0; block "expected one open PR for #$n, found: ${prs:-none}"; }
PR="${prs%%$'\t'*}"; BRANCH="${prs#*$'\t'}"
head_of_pr() { "$GH" pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid; }
HEAD_SHA="$(head_of_pr)"

# 2. the head must be the approved commit or one of this pipeline's recorded merges after it
accepted="$("$GH" issue view "$n" --repo "$REPO" --json comments --jq '.comments[].body' | tr -d '\r' | awk '
  /^staged-head: [0-9a-f]+/  { list = $2 "\n"; next }
  /^deploy-merge: [0-9a-f]+/ { list = list $2 "\n" }
  END { printf "%s", list }')"
if ! printf '%s\n' "$accepted" | grep -qx "$HEAD_SHA"; then
  [ "$mode" = --refresh ] && { say "head $HEAD_SHA is not approved; not refreshing"; exit 0; }
  block "PR #$PR changed after it was staged (head $HEAD_SHA is neither the staged-head nor a deploy-merge)"
fi

# 3. worktree at the PR head
git -C "$FACTORY_REPO" fetch -q origin || { echo "deploy: fetch failed" >&2; exit 2; }
if [ ! -e "$WT/.git" ]; then
  git -C "$FACTORY_REPO" worktree add -q -B "$BRANCH" "$WT" "origin/$BRANCH" || { echo "deploy: cannot create $WT" >&2; exit 2; }
elif [ "$mode" != --continue ]; then
  g checkout -q "$BRANCH" 2>/dev/null || g checkout -q -B "$BRANCH" "origin/$BRANCH"
  reset_worktree
fi

merge_main() {  # 0 up to date · 1 merged cleanly · 3 conflicts to resolve · 4 conflicts beyond the criteria (REASON)
  g merge-base --is-ancestor "origin/$MAIN" HEAD && return 0
  if g merge --no-ff --no-edit -m "Merge origin/$MAIN into $BRANCH" -m "$TRAILER" "origin/$MAIN" >"$TMP/merge.txt" 2>&1; then return 1; fi
  CONFLICTS="$(g diff --name-only --diff-filter=U)"
  [ -n "$CONFLICTS" ] || { REASON="merge failed: $(tail -3 "$TMP/merge.txt")"; return 4; }
  local files hunks=0 f layer re
  files="$(printf '%s\n' "$CONFLICTS" | grep -c .)"
  while IFS= read -r f; do hunks=$(( hunks + $(grep -c '^<<<<<<<' "$WT/$f" 2>/dev/null || echo 0) )); done <<< "$CONFLICTS"
  for layer in $(mylos_cfg layers); do
    re="$(mylos_cfg regex migrations "$layer")"
    if [ -n "$re" ] && printf '%s\n' "$CONFLICTS" | grep -Eq -- "$re"; then
      REASON="a migration conflicts with main: $(printf '%s\n' "$CONFLICTS" | grep -E -- "$re" | tr '\n' ' ')"; return 4
    fi
  done
  [ "$files" -gt "$MAX_FILES" ] && { REASON="$files files conflict with main (limit $MAX_FILES)"; return 4; }
  [ "$hunks" -gt "$MAX_HUNKS" ] && { REASON="$hunks hunks conflict with main (limit $MAX_HUNKS)"; return 4; }
  return 3
}

fast_gates() {  # deterministic checks only: CI runs build and tests on this exact head
  local mb slug spec qa
  mb="$(g merge-base HEAD "origin/$MAIN")"
  slug="${BRANCH#feat/$n-}"; spec="$(ls "$WT/$SPECS"*-"$slug"-design.md 2>/dev/null | head -1)"
  qa="$(g log --format=%H -1 --grep "acceptance tests for #$n")"
  {
    bash "$GATE" -C "$WT" forbidden "$mb" &&
    bash "$GATE" -C "$WT" migration "$mb" "${spec:-/dev/null}" &&
    { [ -z "$qa" ] || bash "$GATE" -C "$WT" acceptance-intact "$qa"; }
  } >"$TMP/gates.txt" 2>&1
}

wait_checks() {  # wait_checks <sha>: 0 green, 1 red or timed out
  local sha="$1" deadline=$(( $(date +%s) + 1800 )) out head states empty=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    out="$("$GH" pr view "$PR" --repo "$REPO" --json headRefOid,statusCheckRollup --jq \
      '.headRefOid + " " + ([.statusCheckRollup[] | (if (.conclusion // "") != "" then .conclusion else (.state // .status // "") end)] | join(","))' 2>/dev/null)"
    head="${out%% *}"; states="${out#* }"; [ "$states" = "$out" ] && states=""
    if [ "$head" = "$sha" ]; then
      if [ -z "$states" ]; then
        empty=$((empty + 1)); [ "$empty" -ge 10 ] && { say "no checks reported for $sha"; return 0; }
      elif printf '%s' "$states" | grep -Eqi 'FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE'; then
        say "checks failed on $sha: $states"; return 1
      elif ! printf '%s' "$states" | tr ',' '\n' | grep -Eqvi '^(SUCCESS|NEUTRAL|SKIPPED)$'; then
        return 0
      fi
    fi
    sleep "$POLL"
  done
  say "checks did not finish in 30 minutes"; return 1
}

# 4-8. up to date with main, fast gates, pushed, green
merged=0
[ "$mode" = --continue ] && {
  g rev-parse -q --verify MERGE_HEAD >/dev/null && block "--continue with the merge still in progress"
  [ -n "$(g diff --name-only --diff-filter=U)" ] && block "--continue with unresolved conflicts"
  merged=1
}
for attempt in 1 2 3; do
  if [ "$mode" != --continue ] || [ "$attempt" -gt 1 ]; then
    merge_main; rc=$?
    case "$rc" in
      1) merged=1 ;;
      3) if [ "$mode" = --refresh ]; then reset_worktree; say "conflicts with main; left for the deploy"; exit 0; fi
         printf 'CONFLICT %s\n' $CONFLICTS; say "resolve these conflicts, commit, then run: deploy.sh $n --continue"; exit 3 ;;
      4) if [ "$mode" = --refresh ]; then reset_worktree; say "$REASON; left for the deploy"; exit 0; fi
         back_to_coding "$REASON" ;;
    esac
  fi
  if ! fast_gates; then
    if [ "$merged" = 1 ]; then back_to_coding "gates failed after merging main: $(tail -5 "$TMP/gates.txt" | tr '\n' ' ')"; fi
    block "gates failed: $(tail -5 "$TMP/gates.txt" | tr '\n' ' ')"
  fi
  sha="$(g rev-parse HEAD)"
  if [ "$sha" != "$(g rev-parse "origin/$BRANCH")" ]; then
    g push -q origin "HEAD:$BRANCH" || block "push of $sha failed"
    comment "deploy-merge: $sha $(g rev-parse "origin/$MAIN")"
    say "merged main into the PR: $sha"
  fi
  [ "$mode" = --refresh ] && { say "up to date with main"; exit 0; }
  if ! wait_checks "$sha"; then
    [ "$merged" = 1 ] && back_to_coding "CI failed on the PR after merging main ($sha)"
    block "CI failed on the PR ($sha)"
  fi
  g fetch -q origin
  g merge-base --is-ancestor "origin/$MAIN" HEAD && break
  say "main moved while waiting for CI; updating again"
  [ "$attempt" = 3 ] && block "main kept moving; three updates in a row"
  mode=deploy
done

# 9. merge
"$GH" pr merge "$PR" --repo "$REPO" --squash --match-head-commit "$sha" >"$TMP/merge-pr.txt" 2>&1 \
  || block "gh pr merge failed: $(tail -3 "$TMP/merge-pr.txt" | tr '\n' ' ')"
MERGED="$("$GH" pr view "$PR" --repo "$REPO" --json mergeCommit --jq .mergeCommit.oid)"
say "merged as $MERGED"

# 10. production
failure=""; deploy_url=""
if [ -n "$CI_WORKFLOW" ]; then
  run=""; for _ in $(seq 1 10); do
    run="$("$GH" run list --repo "$REPO" --branch "$MAIN" --commit "$MERGED" --workflow "$CI_WORKFLOW" --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
    [ -n "$run" ] && break; sleep "$POLL"
  done
  if [ -z "$run" ]; then failure="no '$CI_WORKFLOW' run on $MAIN for $MERGED"
  elif ! "$GH" run watch "$run" --repo "$REPO" --exit-status >/dev/null 2>&1; then failure="CI on $MAIN failed (run $run)"; fi
fi
if [ -z "$failure" ] && [ -n "$ENVIRONMENT" ]; then
  deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 )); state=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    d="$("$GH" api "repos/$REPO/deployments?sha=$MERGED" --jq "[.[] | select(.environment == \"$ENVIRONMENT\")][0].id" 2>/dev/null)"
    if [ -n "$d" ] && [ "$d" != null ]; then
      state="$("$GH" api "repos/$REPO/deployments/$d/statuses" --jq '.[0].state' 2>/dev/null)"
      case "$state" in
        success) deploy_url="$("$GH" api "repos/$REPO/deployments/$d/statuses" --jq '.[0].environment_url // ""' 2>/dev/null)"; break ;;
        failure|error) break ;;
      esac
    fi
    sleep "$POLL"
  done
  [ "$state" = success ] || failure="deployment to '$ENVIRONMENT' ended '${state:-timeout}'"
fi
if [ -z "$failure" ] && [ -n "$HEALTH" ]; then
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    ok=0; for _ in 1 2 3 4 5; do "$CURL" -fsS -o /dev/null -m 10 "$url" >/dev/null 2>&1 && { ok=1; break; }; sleep "$(( POLL / 2 ))"; done
    [ "$ok" = 1 ] || { failure="health check failed: $url"; break; }
  done <<< "$HEALTH"
fi

if [ -n "$failure" ]; then  # revert, reopen, block
  rw="$FACTORY_WT_ROOT/revert-$n"
  git -C "$FACTORY_REPO" fetch -q origin
  git -C "$FACTORY_REPO" worktree add -q -B "revert/$n" "$rw" "origin/$MAIN" 2>/dev/null || git -C "$rw" reset -q --hard "origin/$MAIN"
  if git -C "$rw" revert --no-commit "$MERGED" && git -C "$rw" commit -qm "revert: #$n after a failed production deploy" -m "$TRAILER" \
     && git -C "$rw" push -q -u origin "revert/$n"; then
    rpr="$("$GH" pr create --repo "$REPO" --base "$MAIN" --head "revert/$n" --title "revert: #$n" \
      --body "Reverts the merge of #$n ($MERGED) after a failed production deploy: $failure. Refs #$n." 2>&1 | tail -1)"
  else rpr="(revert could not be prepared: see $rw)"; fi
  "$GH" issue reopen "$n" --repo "$REPO" >/dev/null 2>&1
  comment "Production deploy failed: $failure. Revert PR: $rpr
staged-head: $(git -C "$rw" rev-parse HEAD)"
  "$GH" issue edit "$n" --repo "$REPO" --add-label blocked >/dev/null
  say "failed after merge: $failure; revert $rpr"; exit 6
fi

# 11. done
"$BOARD" move "$n" Done >/dev/null || say "could not move the card to Done"
mins=$(( ($(date +%s) - START) / 60 ))
comment "Deployed: merge $MERGED${deploy_url:+ · $deploy_url} · $mins min from start of the deploy."
git -C "$FACTORY_REPO" worktree remove --force "$WT" >/dev/null 2>&1
say "done in $mins min"
exit 0
