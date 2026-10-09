#!/usr/bin/env bash
# Deterministic deploy of one card (docs/superpowers/specs/2026-10-09-fast-safe-deploy-design.md).
# usage: deploy.sh <n> [--refresh | --continue]
#   --refresh   bring a Staged card's PR up to date with main (clean merges only); never merges to main
#   --continue  resume after the conflicts printed by a previous run were resolved and committed
# exit: 0 done · 3 conflicts to resolve · 4 sent back to Coding · 5 blocked · 6 failed after merge (reverted)
#       2 usage, configuration, transient API error or busy card (safe to retry)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/project.sh"

n="${1:-}"; mode="${2:-deploy}"
case "$mode" in deploy|--refresh|--continue) ;; *) n="" ;; esac
[[ "$n" =~ ^[0-9]+$ ]] || { echo "usage: deploy.sh <n> [--refresh | --continue]" >&2; exit 2; }
mylos_resolve . || exit 2
mapfile -d '' -t V < <(mylos_cfg values project.repo project.main deploy.ci_workflow deploy.environment \
  deploy.timeout_min deploy.conflict_max_files deploy.conflict_max_hunks paths.specs deploy.allow_no_checks   deploy.healthcheck deploy.required_checks)
[ "${#V[@]}" -eq 11 ] || { echo "deploy: cannot read the project config" >&2; exit 2; }
REPO="${V[0]}" MAIN="${V[1]}" CI_WORKFLOW="${V[2]}" ENVIRONMENT="${V[3]}"
TIMEOUT_MIN="${V[4]:-30}" MAX_FILES="${V[5]:-5}" MAX_HUNKS="${V[6]:-20}" SPECS="${V[7]}" ALLOW_NO_CHECKS="${V[8]:-false}"
HEALTH="${V[9]}" REQUIRED="${V[10]}"  # lists, one item per line
GH="${FACTORY_GH:-gh}"; BOARD="${FACTORY_BOARD:-$HERE/board.sh}"; GATE="$HERE/gate.sh"
CURL="${FACTORY_CURL:-curl}"; POLL="${FACTORY_POLL:-30}"
WT="$FACTORY_WT_ROOT/$n"; TMP="$FACTORY_HOME/tmp/$n"; mkdir -p "$TMP"
TRAILER="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
START="$(date +%s)"; BRANCH=""; PR=""
polls() { local secs="$1"; [ "$POLL" -gt 0 ] && echo $(( secs / POLL + 1 )) || echo 60; }

TAB=$'\t'
# the PR's branch as one whole tab-separated field; inside a bracket expression "\t" is a backslash
# and a "t", not a tab, so the tab is spliced in
PR_FIELD="${TAB}(feat/$n-[^${TAB}]*|revert/$n)${TAB}"
say() { echo "deploy #$n: $*"; }
g() { git -C "$WT" "$@"; }
comment() { "$GH" issue comment "$n" --repo "$REPO" --body "$1" >/dev/null || { say "could not comment on #$n"; return 1; }; }
reset_worktree() {  # drop any merge in progress or local commit: back to the approved head
  [ -n "$BRANCH" ] && [ -e "$WT/.git" ] || return 0
  g merge --abort >/dev/null 2>&1; g reset -q --hard "${HEAD_SHA:-origin/$BRANCH}" 2>/dev/null; g clean -qfd 2>/dev/null; return 0
}
block() {  # before merging: label, explain, stop
  reset_worktree
  comment "Factory deploy stopped: $1"
  "$GH" issue edit "$n" --repo "$REPO" --add-label blocked >/dev/null || say "could not label #$n blocked"
  say "blocked: $1"; exit 5
}
back_to_coding() {
  reset_worktree
  [ "$mode" = --refresh ] && { say "$1; left for the deploy"; exit 0; }
  comment "Back to Coding: $1"
  "$BOARD" move "$n" Coding >/dev/null || { say "could not move the card to Coding"; exit 2; }
  say "back to Coding: $1"; exit 4
}
retry_later() { say "$1; will retry"; exit 2; }

# one deploy.sh per card at a time (refresh, deploy, continue), whoever started it
LOCK="$FACTORY_HOME/locks/deploysh-$n.lock"; mkdir -p "$FACTORY_HOME/locks"
if ! mkdir "$LOCK" 2>/dev/null; then
  held="$(cut -d' ' -f1 "$LOCK/info" 2>/dev/null)"
  if [ -n "$held" ] && kill -0 "$held" 2>/dev/null; then say "another deploy.sh runs on this card (pid $held)"; exit 2; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 2
fi
echo "$$ $(date +%s)" > "$LOCK/info"; trap 'rm -rf "$LOCK"' EXIT

# 1. card and PR
status="$("$BOARD" status "$n")" || retry_later "cannot read the board"
if [ "$mode" = --refresh ]; then
  [ "$status" = Staged ] || { say "not Staged ($status); nothing to refresh"; exit 0; }
elif [ "$status" != "Ready for Prod" ]; then
  say "#$n is in '$status', not Ready for Prod"; exit 2
fi
ME="$("$GH" api user --jq .login)" || retry_later "cannot read the GitHub user"
list="$("$GH" pr list --repo "$REPO" --state open --base "$MAIN" --json number,headRefName,isCrossRepository,headRefOid \
  --jq '.[] | "\(.number)\t\(.headRefName)\t\(.isCrossRepository)\t\(.headRefOid)"')" || retry_later "cannot list PRs"
prs="$(printf '%s\n' "$list" | grep -E -- "$PR_FIELD" || true)"

resume_merged() {  # the PR was merged by an earlier run that stopped before production was checked
  local m; m="$("$GH" pr list --repo "$REPO" --state merged --base "$MAIN" --json number,headRefName,mergeCommit \
    --jq '.[] | "\(.number)\t\(.headRefName)\t\(.mergeCommit.oid // "")"')" || retry_later "cannot list merged PRs"
  m="$(printf '%s\n' "$m" | grep -E -- "$PR_FIELD" | head -1)"
  [ -n "$m" ] || return 1
  PR="${m%%$'\t'*}"; m="${m#*$'\t'}"; BRANCH="${m%%$'\t'*}"; MERGED="${m#*$'\t'}"
  [[ "$MERGED" =~ ^[0-9a-f]{40}$ ]] || return 1
  git -C "$FACTORY_REPO" fetch -q origin || retry_later "fetch failed"
  git -C "$FACTORY_REPO" merge-base --is-ancestor "$MERGED" "origin/$MAIN" || return 1
  say "PR #$PR was already merged as $MERGED; checking production"; return 0
}
if [ "$(printf '%s' "$prs" | grep -c .)" -ne 1 ]; then
  [ "$mode" = --refresh ] && exit 0
  if [ -z "$prs" ] && resume_merged; then RESUMED=1; else block "expected one open PR for #$n, found: ${prs:-none}"; fi
else
  RESUMED=0
  IFS=$'\t' read -r PR BRANCH cross HEAD_SHA <<< "$prs"
  [ "$cross" = false ] || block "PR #$PR comes from a fork; the factory deploys only its own branches"
fi

if [ "$RESUMED" = 0 ]; then
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || retry_later "PR #$PR has no head sha"

  # 2. approval: the factory's own comments only. The newest staged-head is the owner-approved commit
  #    (the owner approved it by moving the card); deploy-merge heads are this script's merges of main.
  bodies="$("$GH" issue view "$n" --repo "$REPO" --json comments \
    --jq ".comments[] | select(.author.login == \"$ME\") | .body")" || retry_later "cannot read #$n comments"
  APPROVED="$(printf '%s\n' "$bodies" | tr -d '\r' | sed -n 's/^staged-head: \([0-9a-f]\{40\}\).*/\1/p' | tail -1)"
  [ -n "$APPROVED" ] || block "no staged-head comment on #$n"
  RECORDED="$(printf '%s\n' "$bodies" | tr -d '\r' | awk -v a="$APPROVED" '
    $1 == "staged-head:" { on = ($2 == a); next }
    on && $1 == "deploy-merge:" && $2 ~ /^[0-9a-f]+$/ { print $2 }')"

  # 3. worktree exactly at the PR head GitHub reported
  git -C "$FACTORY_REPO" fetch -q origin || retry_later "fetch failed"
  [ "$(git -C "$FACTORY_REPO" rev-parse "origin/$BRANCH" 2>/dev/null)" = "$HEAD_SHA" ] \
    || retry_later "origin/$BRANCH is not the PR head $HEAD_SHA yet"
  approved_chain() {  # HEAD_SHA is the approved commit, or a recorded merge of main on top of an approved chain
    local c="$HEAD_SHA" p1 p2
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$c" = "$APPROVED" ] && return 0
      printf '%s\n' "$RECORDED" | grep -qxF -- "$c" || return 1
      p1="$(git -C "$FACTORY_REPO" rev-parse -q --verify "$c^1")" && p2="$(git -C "$FACTORY_REPO" rev-parse -q --verify "$c^2")" || return 1
      git -C "$FACTORY_REPO" merge-base --is-ancestor "$p2" "origin/$MAIN" || return 1
      c="$p1"
    done
    return 1
  }
  if ! approved_chain; then
    [ "$mode" = --refresh ] && { say "head $HEAD_SHA is not approved; not refreshing"; exit 0; }
    block "PR #$PR changed after it was staged (head $HEAD_SHA is not the staged-head nor a recorded merge of main on it)"
  fi
  if [ ! -e "$WT/.git" ]; then
    git -C "$FACTORY_REPO" worktree add -q -B "$BRANCH" "$WT" "$HEAD_SHA" || retry_later "cannot create $WT"
  elif [ "$mode" != --continue ]; then
    g checkout -q -B "$BRANCH" "$HEAD_SHA" 2>/dev/null || { g merge --abort >/dev/null 2>&1; g checkout -q -f -B "$BRANCH" "$HEAD_SHA"; } \
      || retry_later "cannot check out $BRANCH in $WT"
    reset_worktree
  fi
fi

merge_main() {  # 0 up to date · 1 merged cleanly · 3 conflicts to resolve · 4 conflicts beyond the criteria (REASON)
  g merge-base --is-ancestor "origin/$MAIN" HEAD && return 0
  local main_sha; main_sha="$(g rev-parse "origin/$MAIN")"
  if g merge --no-ff --no-edit -m "Merge origin/$MAIN into $BRANCH" -m "$TRAILER" "$main_sha" >"$TMP/merge.txt" 2>&1; then return 1; fi
  CONFLICTS="$(g diff --name-only --diff-filter=U)"
  [ -n "$CONFLICTS" ] || { REASON="merge failed: $(tail -3 "$TMP/merge.txt" | tr '\n' ' ')"; return 4; }
  local files hunks=0 f c layer re
  files="$(printf '%s\n' "$CONFLICTS" | grep -c .)"
  while IFS= read -r f; do c="$(grep -c '^<<<<<<<' "$WT/$f" 2>/dev/null)"; hunks=$(( hunks + ${c:-0} )); done <<< "$CONFLICTS"
  for layer in $(mylos_cfg layers); do
    re="$(mylos_cfg regex migrations "$layer")"
    if [ -n "$re" ] && printf '%s\n' "$CONFLICTS" | grep -Eq -- "$re"; then
      REASON="a migration conflicts with main: $(printf '%s\n' "$CONFLICTS" | grep -E -- "$re" | tr '\n' ' ')"; return 4
    fi
  done
  [ "$files" -gt "$MAX_FILES" ] && { REASON="$files files conflict with main (limit $MAX_FILES)"; return 4; }
  [ "$hunks" -gt "$MAX_HUNKS" ] && { REASON="$hunks hunks conflict with main (limit $MAX_HUNKS)"; return 4; }
  printf '%s\n' "$HEAD_SHA" "$main_sha" > "$TMP/resolve.parents"; printf '%s\n' "$CONFLICTS" > "$TMP/resolve.files"
  return 3
}

check_resolution() {  # --continue: HEAD must be the merge of the approved head and main, changing only conflicted files
  local p1 p2 extra
  g rev-parse -q --verify MERGE_HEAD >/dev/null && block "--continue with the merge still in progress"
  [ -n "$(g diff --name-only --diff-filter=U)" ] && block "--continue with unresolved conflicts"
  [ -s "$TMP/resolve.parents" ] || block "--continue without a conflict handed over by deploy.sh"
  { read -r p1; read -r p2; } < "$TMP/resolve.parents"
  [ "$(g rev-parse -q --verify HEAD^1)" = "$p1" ] && [ "$(g rev-parse -q --verify HEAD^2)" = "$p2" ] \
    || block "--continue: HEAD is not the merge of $p1 and $p2"
  [ "$p1" = "$HEAD_SHA" ] || block "--continue: the PR head moved since the conflicts were handed over"
  extra="$(comm -12 <(g diff --name-only HEAD^1 HEAD | sort) <(g diff --name-only HEAD^2 HEAD | sort) | grep -vxF -f "$TMP/resolve.files" || true)"
  [ -z "$extra" ] || block "--continue: the resolution changed files that did not conflict: $(echo $extra)"
  rm -f "$TMP/resolve.parents" "$TMP/resolve.files"
}

fast_gates() {  # deterministic checks only: CI runs build and tests on this exact head
  local mb slug spec qa
  mb="$(g merge-base HEAD "origin/$MAIN")"
  case "$BRANCH" in revert/*)  # a revert removes what the card added: only the forbidden paths apply
    bash "$GATE" -C "$WT" forbidden "$mb" >"$TMP/gates.txt" 2>&1; return ;;
  esac
  slug="${BRANCH#feat/$n-}"; spec="$(ls "$WT/$SPECS"*-"$slug"-design.md 2>/dev/null | head -1)"
  qa="$(g log --format=%H -1 -E --grep "acceptance tests for #$n([^0-9]|\$)" "$mb..HEAD")"
  bash "$GATE" -C "$WT" fast "$mb" "${spec:-/dev/null}" $qa >"$TMP/gates.txt" 2>&1
}

wait_checks() {  # wait_checks <sha>: 0 green, 1 red or timed out
  local sha="$1" out head states empty=0 settle=0 req
  for _ in $(seq 1 "$(polls 1800)"); do
    out="$("$GH" pr view "$PR" --repo "$REPO" --json headRefOid,statusCheckRollup --jq \
      '.headRefOid + " " + ([.statusCheckRollup[] | (.name // .context // "") + "=" + (if (.conclusion // "") != "" then .conclusion else (.state // .status // "") end)] | join(","))' 2>/dev/null)"
    head="${out%% *}"; states="${out#* }"; [ "$states" = "$out" ] && states=""
    if [ "$head" = "$sha" ]; then
      if [ -z "$states" ]; then
        empty=$((empty + 1))
        [ "$empty" -ge 10 ] && [ "$ALLOW_NO_CHECKS" = true ] && { say "no checks reported for $sha (allowed)"; return 0; }
      elif printf '%s' "$states" | grep -Eqi '=(FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE|STALE)'; then
        say "checks failed on $sha: $states"; return 1
      elif ! printf '%s' "$states" | tr ',' '\n' | grep -Eqvi '=(SUCCESS|NEUTRAL|SKIPPED)$'; then
        local missing=""
        while IFS= read -r req; do
          [ -n "$req" ] && ! printf '%s' ",$states," | grep -qF ",$req=" && missing="$missing $req"
        done <<< "$REQUIRED"
        settle=$((settle + 1))  # late workflows register after the first ones finish: see green twice
        [ -z "$missing" ] && [ "$settle" -ge 2 ] && return 0
      fi
    fi
    sleep "$POLL"
  done
  say "checks did not finish (last: ${states:-none})"; return 1
}

push_recorded() {  # record the merge before pushing it: an unpushed record is harmless, an unrecorded push wedges the card
  local sha="$1"
  [ "$("$BOARD" status "$n")" = "$status" ] || retry_later "the card moved meanwhile"
  comment "deploy-merge: $sha $(g rev-parse "origin/$MAIN")" || retry_later "cannot record the merge"
  g push -q --force-with-lease="$BRANCH:$HEAD_SHA" origin "HEAD:$BRANCH" || block "push of $sha failed (the branch moved?)"
  RECORDED="$RECORDED"$'\n'"$sha"; HEAD_SHA="$sha"
  say "merged main into the PR: $sha"
}

# 4-8. up to date with main, fast gates, pushed, green
if [ "$RESUMED" = 0 ]; then
  merged=0
  if [ "$mode" = --continue ]; then check_resolution; merged=1; fi
  for attempt in 1 2 3; do
    if [ "$mode" != --continue ] || [ "$attempt" -gt 1 ]; then
      merge_main; rc=$?
      case "$rc" in
        1) merged=1 ;;
        3) if [ "$mode" = --refresh ]; then reset_worktree; say "conflicts with main; left for the deploy"; exit 0; fi
           while IFS= read -r f; do printf 'CONFLICT %s\n' "$f"; done <<< "$CONFLICTS"
           say "resolve these conflicts, commit, then run: deploy.sh $n --continue"; trap - EXIT; rm -rf "$LOCK"; exit 3 ;;
        4) back_to_coding "$REASON" ;;
      esac
    fi
    if ! fast_gates; then
      [ "$merged" = 1 ] && back_to_coding "gates failed after merging main: $(tail -5 "$TMP/gates.txt" | tr '\n' ' ')"
      block "gates failed: $(tail -5 "$TMP/gates.txt" | tr '\n' ' ')"
    fi
    sha="$(g rev-parse HEAD)"
    [ "$sha" != "$HEAD_SHA" ] && push_recorded "$sha"
    [ "$mode" = --refresh ] && { say "up to date with main"; exit 0; }
    if ! wait_checks "$sha"; then
      [ "$merged" = 1 ] && back_to_coding "CI failed on the PR after merging main ($sha)"
      block "CI failed on the PR ($sha)"
    fi
    g fetch -q origin || retry_later "fetch failed"
    g merge-base --is-ancestor "origin/$MAIN" HEAD && break
    say "main moved while waiting for CI; updating again"
    [ "$attempt" = 3 ] && block "main kept moving; three updates in a row"
    mode=deploy
  done

  # 9. merge
  if ! "$GH" pr merge "$PR" --repo "$REPO" --squash --match-head-commit "$sha" >"$TMP/merge-pr.txt" 2>&1; then
    state="$("$GH" pr view "$PR" --repo "$REPO" --json state --jq .state 2>/dev/null)"
    [ "$state" = MERGED ] || block "gh pr merge failed: $(tail -3 "$TMP/merge-pr.txt" | tr '\n' ' ')"
  fi
  MERGED=""
  for _ in $(seq 1 10); do
    MERGED="$("$GH" pr view "$PR" --repo "$REPO" --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null)"
    [[ "$MERGED" =~ ^[0-9a-f]{40}$ ]] && break; sleep "$POLL"
  done
  [[ "$MERGED" =~ ^[0-9a-f]{40}$ ]] || retry_later "PR #$PR merged but its merge commit is not known yet"
  say "merged as $MERGED"
fi

# 10. production
failure=""; deploy_url=""
if [ -n "$CI_WORKFLOW" ]; then
  run=""; for _ in $(seq 1 10); do
    run="$("$GH" run list --repo "$REPO" --branch "$MAIN" --commit "$MERGED" --workflow "$CI_WORKFLOW" --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
    [ -n "$run" ] && break; sleep "$POLL"
  done
  if [ -z "$run" ]; then failure="no '$CI_WORKFLOW' run on $MAIN for $MERGED"
  else
    for _ in $(seq 1 "$(polls $(( TIMEOUT_MIN * 60 )))"); do
      concl="$("$GH" run view "$run" --repo "$REPO" --json status,conclusion --jq '.status + " " + (.conclusion // "")' 2>/dev/null)"
      case "$concl" in "completed success") break ;; completed*) failure="CI on $MAIN failed (run $run: ${concl#completed })"; break ;; esac
      sleep "$POLL"
    done
    [ -z "$failure" ] && [ "$concl" != "completed success" ] && failure="CI on $MAIN did not finish (run $run)"
  fi
fi
if [ -z "$failure" ] && [ -n "$ENVIRONMENT" ]; then
  state=""
  for _ in $(seq 1 "$(polls $(( TIMEOUT_MIN * 60 )))"); do
    d="$("$GH" api "repos/$REPO/deployments?sha=$MERGED" --jq "[.[] | select(.environment == \"$ENVIRONMENT\")][0].id" 2>/dev/null)"
    if [ -n "$d" ] && [ "$d" != null ]; then
      state="$("$GH" api "repos/$REPO/deployments/$d/statuses" --jq '.[0].state' 2>/dev/null)"
      case "$state" in
        success) deploy_url="$("$GH" api "repos/$REPO/deployments/$d/statuses" --jq '.[0].environment_url // ""' 2>/dev/null)"; break ;;
        inactive) say "deployment $d superseded by a newer one"; break ;;
        failure|error) break ;;
      esac
    fi
    sleep "$POLL"
  done
  case "$state" in success|inactive) ;; *) failure="deployment to '$ENVIRONMENT' ended '${state:-timeout}'" ;; esac
fi
if [ -z "$failure" ] && [ -n "$HEALTH" ]; then
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    ok=0; for _ in 1 2 3 4 5; do "$CURL" -fsS -o /dev/null -m 10 "$url" >/dev/null 2>&1 && { ok=1; break; }; sleep "$(( POLL / 2 ))"; done
    [ "$ok" = 1 ] || { failure="health check failed: $url"; break; }
  done <<< "$HEALTH"
fi

if [ -n "$failure" ]; then  # revert, reopen, block
  rw="$FACTORY_WT_ROOT/revert-$n"; rpr=""
  git -C "$FACTORY_REPO" worktree remove --force "$rw" >/dev/null 2>&1
  if git -C "$FACTORY_REPO" fetch -q origin && git -C "$FACTORY_REPO" worktree add -q --detach "$rw" "origin/$MAIN" \
     && git -C "$rw" revert --no-commit "$MERGED" && git -C "$rw" commit -qm "revert: #$n after a failed production deploy" -m "$TRAILER" \
     && git -C "$rw" push -q origin "HEAD:refs/heads/revert/$n"; then
    rhead="$(git -C "$rw" rev-parse HEAD)"
    rpr="$("$GH" pr create --repo "$REPO" --base "$MAIN" --head "revert/$n" --title "revert: #$n" \
      --body "Reverts the merge of #$n ($MERGED) after a failed production deploy: $failure. Refs #$n." 2>/dev/null | tail -1)" \
      || rpr="(revert branch revert/$n pushed; opening its PR failed)"
    git -C "$FACTORY_REPO" worktree remove --force "$rw" >/dev/null 2>&1
    comment "Production deploy failed: $failure. Revert PR: $rpr
staged-head: $rhead"
  else
    comment "Production deploy failed: $failure. The revert could not be prepared automatically: revert $MERGED by hand."
  fi
  "$GH" issue reopen "$n" --repo "$REPO" >/dev/null 2>&1
  "$GH" issue edit "$n" --repo "$REPO" --add-label blocked >/dev/null || say "could not label #$n blocked"
  say "failed after merge: $failure; revert ${rpr:-not prepared}"; exit 6
fi

# 11. done
"$BOARD" move "$n" Done >/dev/null || say "could not move the card to Done"
mins=$(( ($(date +%s) - START) / 60 ))
comment "Deployed: merge $MERGED${deploy_url:+ · $deploy_url} · $mins min from the start of this deploy run."
git -C "$FACTORY_REPO" worktree remove --force "$WT" >/dev/null 2>&1
say "done in $mins min"
exit 0
