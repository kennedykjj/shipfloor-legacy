#!/usr/bin/env bash
# Helpers for factory script tests. Each test file sources this.
FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
export FACTORY_HOME="${FACTORY_HOME:-$(mktemp -d)}"  # never touch the real ~/.mylos
export FACTORY_CLEANUP=0   # never stop real processes from tests
export FACTORY_CONFIG="${FACTORY_CONFIG:-$FACTORY_DIR/test/fixture/factory.yml}"
export MYLOS_HOME="${MYLOS_HOME:-$(mktemp -d)}"  # never touch the real ~/.mylos

new_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t; git -C "$dir" config core.autocrlf false
  echo base > "$dir/README.md"
  git -C "$dir" add -A; git -C "$dir" commit -qm base
  echo "$dir"
}

assert_exit() {
  local want="$1"; shift
  local out; out="$("$@" 2>&1)"; local got=$?
  if [ "$got" -eq "$want" ]; then pass "$*"; else fail "$* → exit $got, want $want: $out"; fi
}

assert_contains() {
  case "$1" in *"$2"*) pass "contains $2" ;; *) fail "missing '$2' in: $1" ;; esac
}

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }
finish() { [ "$FAILS" -eq 0 ]; }
