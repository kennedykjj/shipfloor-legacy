#!/usr/bin/env bash
# Shared setup for the deploy.sh tests (deploy-*.test.sh): one base repo per file, a private copy per case.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "$0")/lib.sh"
DEP="$FACTORY_DIR/deploy.sh"
M=api/src/main/resources/db/migration

build_base() {  # once per file: remote + clone with main and the staged card #7 on feat/7-x
  BASE="$(mktemp -d)"; git init -q --bare "$BASE/remote.git"
  local r="$BASE/repo"; git init -q -b main "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t; git -C "$r" config core.autocrlf false
  git -C "$r" remote add origin "$BASE/remote.git"
  mkdir -p "$r/$M" "$r/docs/superpowers/specs"; echo 'create table a (id int);' > "$r/$M/V1__a.sql"
  printf '# x

## Rollback

n/a
' > "$r/docs/superpowers/specs/2026-01-01-x-design.md"
  echo base > "$r/README.md"; echo shared > "$r/shared.txt"
  git -C "$r" add -A; git -C "$r" commit -qm main; git -C "$r" push -q origin main
  git -C "$r" checkout -qb feat/7-x
  mkdir -p "$r/api/src/test"; echo test > "$r/api/src/test/ATest.kt"; git -C "$r" add -A; git -C "$r" commit -qm "test(x): acceptance tests for #7"
  echo impl > "$r/api/A.kt"; git -C "$r" add -A; git -C "$r" commit -qm "feat(x): impl"
  git -C "$r" push -q origin feat/7-x; git -C "$r" checkout -q main
  STAGED="$(git -C "$r" rev-parse feat/7-x)"
}
build_base

setup() {  # each case: a private copy of the base (no git work), plus fresh fakes
  T="$(mktemp -d)"; cp -r "$BASE/remote.git" "$BASE/repo" "$T/"
  remote="$T/remote.git"; repo="$T/repo"; git -C "$repo" remote set-url origin "$remote"
  export FG="$T/fg"; mkdir -p "$FG"; echo "$remote" > "$FG/remote"
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
  export FACTORY_CONFIG="$T/factory.yml"
  sed '/^deploy:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$FACTORY_CONFIG"
  echo 'deploy: {healthcheck: ["https://shop.example/health"]}' >> "$FACTORY_CONFIG"
  export FACTORY_HOME="$T/home" FACTORY_WT_ROOT="$T/wt" FACTORY_REPO="$repo" FACTORY_GH="$FACTORY_DIR/test/fake-gh-deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CURL="$T/curl" FACTORY_POLL=0
  mkdir -p "$FACTORY_HOME"
}
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

