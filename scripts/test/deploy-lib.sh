#!/usr/bin/env bash
# Shared setup for the deploy.sh tests (deploy-*.test.sh): one base repo per suite run (run.sh builds it and
# hands it over in DEPLOY_BASE; a file run on its own builds its own), a private copy per case.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DEP="$FACTORY_DIR/deploy.sh"
M=api/src/main/resources/db/migration

build_base() {  # remote + clone with main and the staged card #7 on feat/7-x
  BASE="$(mktemp -d)"; git init -q --bare "$BASE/remote.git"
  local r="$BASE/repo"; git init -q -b main "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t; git -C "$r" config core.autocrlf false
  git -C "$r" remote add origin "$BASE/remote.git"
  mkdir -p "$r/$M" "$r/docs/superpowers/specs"; echo 'create table a (id int);' > "$r/$M/V1__a.sql"
  printf '# x

## Rollback

n/a
' > "$r/docs/superpowers/specs/2026-01-01-x-design.md"
  echo base > "$r/README.md"; echo shared > "$r/shared.txt"; printf 'one
two
three
four
five
' > "$r/lines.txt"
  git -C "$r" add -A; git -C "$r" commit -qm main; git -C "$r" push -q origin main
  git -C "$r" checkout -qb feat/7-x
  mkdir -p "$r/api/src/test"; echo test > "$r/api/src/test/ATest.kt"; git -C "$r" add -A; git -C "$r" commit -qm "test(x): acceptance tests for #7"
  echo impl > "$r/api/A.kt"; git -C "$r" add -A; git -C "$r" commit -qm "feat(x): impl"
  git -C "$r" push -q origin feat/7-x; git -C "$r" checkout -q main
  STAGED="$(git -C "$r" rev-parse feat/7-x)"
}
if [ -d "${DEPLOY_BASE:-}/repo" ]; then BASE="$DEPLOY_BASE"; STAGED="$(git -C "$BASE/repo" rev-parse feat/7-x)"; else build_base; fi

setup() {  # each case: a private copy of the base (no git work), plus fresh fakes
  T="$(mktemp -d)"; cp -r "$BASE/remote.git" "$BASE/repo" "$T/"; point
  git -C "$repo" remote set-url origin "$remote"
  mkdir -p "$FG"; echo "$remote" > "$FG/remote"
  echo 78 > "$FG/pr"; echo feat/7-x > "$FG/branch"; echo "api=SUCCESS" > "$FG/ci"
  printf 'factory	staged-head: %s
' "$STAGED" > "$FG/comments"
  printf '#!/usr/bin/env bash
case "$1" in status) cat "%s/status" ;; move) echo "$3" > "%s/status" ;; esac
' "$FG" "$FG" > "$T/board"
  chmod +x "$T/board"; echo "Ready for Prod" > "$FG/status"
  printf '#!/usr/bin/env bash
exit "$(cat "%s/curl" 2>/dev/null || echo 0)"
' "$FG" > "$T/curl"; chmod +x "$T/curl"
  sed '/^deploy:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$FACTORY_CONFIG"
  echo 'deploy: {healthcheck: ["https://shop.example/health"]}' >> "$FACTORY_CONFIG"
  mkdir -p "$FACTORY_HOME"
}
point() {  # the case lives in $T: where its remote, repo, fakes and factory home are
  remote="$T/remote.git"; repo="$T/repo"
  export FG="$T/fg" FACTORY_CONFIG="$T/factory.yml"
  export FACTORY_HOME="$T/home" FACTORY_WT_ROOT="$T/wt" FACTORY_REPO="$repo" FACTORY_GH="$FACTORY_DIR/test/fake-gh-deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CURL="$T/curl" FACTORY_POLL=0
}
scene() {  # scene <name>: a state several cases start from, built once per file by scene_<name> (after setup)
  # Later calls put a copy of that state back in the same place, because git worktrees hold absolute paths.
  local dir="SCENE_$1" at="SCENE_T_$1" was="SCENE_CODE_$1"
  if [ -z "${!dir:-}" ]; then
    setup; "scene_$1"
    printf -v "$dir" %s "$(mktemp -d)"; printf -v "$at" %s "$T"; printf -v "$was" %s "${code:-}"; cp -r "$T/." "${!dir}/"
  else
    T="${!at}"; rm -rf "$T"; mkdir "$T"; cp -r "${!dir}/." "$T/"; point; code="${!was}"
  fi
}
scene_behind() { main_commit web/other.ts x; }  # another card landed on main: the PR is behind
scene_red() { scene_behind; echo "api=FAILURE" > "$FG/ci"; code="$(run 7)"; }
red_round() { scene red; }  # a deploy that met red CI on top of main and handed the card to a fix round ($code: its exit, 3)
scene_conflict() { on_branch shared.txt card; main_commit shared.txt main; code="$(run 7)"; }  # a small conflict, handed over ($code: 3)
main_commit() {  # main_commit <file> <content>: another card lands on main
  local w; w="$(mktemp -d)"; git clone -q "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
  mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" > "$w/$1"; git -C "$w" add -A; git -C "$w" commit -qm "main: $1"; git -C "$w" push -q origin main
}
on_branch() {  # on_branch <file> <content>: a commit on the card's branch (then re-staged)
  local w; w="$(mktemp -d)"; git clone -q -b feat/7-x "$remote" "$w"; git -C "$w" config user.email t@t; git -C "$w" config user.name t
  mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" > "$w/$1"; git -C "$w" add -A; git -C "$w" commit -qm "card: $1"; git -C "$w" push -q origin feat/7-x
  printf 'factory	staged-head: %s
' "$(git -C "$w" rev-parse HEAD)" >> "$FG/comments"
}
run() { (cd "$repo" && bash "$DEP" "$@" > "$T/out" 2>&1); echo $?; }

fix() {  # fix <file> <lines>: what the agent of a fix round commits in the card's worktree
  local w="$FACTORY_WT_ROOT/7"; mkdir -p "$w/$(dirname "$1")"; seq 1 "$2" > "$w/$1"
  git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm "fix: $1"
}
