#!/usr/bin/env bash
# Helpers for factory script tests. Each test file sources this.
# A test never inherits a factory: when the factory works on this repository, a run comes with FACTORY_HOME,
# FACTORY_CONFIG and SHIPFLOOR_HOME of the real one, and a test would register, pause and remove there.
for v in $(compgen -v FACTORY_; compgen -v SHIPFLOOR_; compgen -v AGHANIM_); do unset "$v"; done; unset v
export SHIPFLOOR_GATE_FRESH=1  # the tests call a gate twice on one commit with another fake runner: it must run (gate-reuse.test.sh unsets it)
# The tests name their branch main. Git for Windows ships init.defaultBranch=main and Linux does not: there a bare
# remote made by a test pointed at master, and a clone of it checked nothing out.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main
FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
export FACTORY_HOME="${FACTORY_HOME:-$(mktemp -d)}"  # never touch the real ~/.shipfloor
export FACTORY_CLEANUP=0   # never stop real processes from tests
export FACTORY_CONFIG="${FACTORY_CONFIG:-$FACTORY_DIR/test/fixture/factory.yml}"
# found once here: a config query runs in a subshell, where what shipfloor_python finds is lost
export FACTORY_PYTHON="${FACTORY_PYTHON:-$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)}"
export SHIPFLOOR_HOME="${SHIPFLOOR_HOME:-$(mktemp -d)}"  # never touch the real ~/.shipfloor

# One template repo per test file; new_repo copies it (one process) instead of six git commands.
REPO_TEMPLATE="$(mktemp -d)"
git -C "$REPO_TEMPLATE" init -q -b main
git -C "$REPO_TEMPLATE" config user.email t@t; git -C "$REPO_TEMPLATE" config user.name t; git -C "$REPO_TEMPLATE" config core.autocrlf false
echo base > "$REPO_TEMPLATE/README.md"
git -C "$REPO_TEMPLATE" add -A; git -C "$REPO_TEMPLATE" commit -qm base

new_repo() {  # new_repo: a fresh repo with one commit (README.md) on main, private to the caller
  local dir; dir="$(mktemp -d)"
  cp -r "$REPO_TEMPLATE/." "$dir/"
  echo "$dir"
}

plugin_copy() {  # plugin_copy: a plain (non-git) copy of scripts/ and templates/ in a temp dir; prints its path
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/scripts"; cp -r "$FACTORY_DIR/." "$dir/scripts/"; cp -r "$FACTORY_DIR/../templates" "$dir/templates"
  rm -rf "$dir/scripts/test"; find "$dir/scripts" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  echo "$dir"
}

# The dashboard's text is a catalog of messages by key (#122): en_msg <key> prints the English one, and <code> <key>
# for another language; empty when there is none.
en_msg() { lang_msg en "$1"; }
# page_english: dashboard.html with each t("key") written out as its English message (test/page_text.py)
page_english() { "$FACTORY_PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); import page_text; sys.stdout.reconfigure(encoding="utf-8"); print(page_text.english(open(sys.argv[2], encoding="utf-8").read()))' "$FACTORY_DIR/test" "$FACTORY_DIR/dashboard.html" | tr -d '\r'; }
lang_msg() { "$FACTORY_PYTHON" -I -c 'import json,sys; sys.stdout.reconfigure(encoding="utf-8"); print(json.load(open(sys.argv[1], encoding="utf-8"))["messages"].get(sys.argv[2], ""))' "$FACTORY_DIR/lang/dashboard.$1.json" "$2" 2>/dev/null | tr -d '\r'; }

assert_exit() {
  local want="$1"; shift
  local out; out="$("$@" 2>&1)"; local got=$?
  if [ "$got" -eq "$want" ]; then pass "$*"; else fail "$* → exit $got, want $want: $out"; fi
}

assert_contains() {
  case "$1" in *"$2"*) pass "contains $2" ;; *) fail "missing '$2' in: $1" ;; esac
}

run_dispatch() {  # run_dispatch: dispatch.sh ($D), then wait until every run it started has ended
  local mark="$FACTORY_HOME/.dispatch-mark" i rc
  mkdir -p "$FACTORY_HOME/locks"; touch "$mark"
  bash "$D" "$@"; rc=$?
  for i in $(seq 1 100); do
    [ -z "$(find "$FACTORY_HOME/locks" -mindepth 1 -maxdepth 1 -name '*-*.lock' -newer "$mark" 2>/dev/null)" ] && break
    sleep 0.1
  done
  return $rc
}

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }
finish() { [ "$FAILS" -eq 0 ]; }
py_suite() {  # py_suite <module> [pattern]: run scripts/test/py/<module>.py in process (unittest), counting its FAIL lines
  local out rc
  out="$("$FACTORY_PYTHON" -I -B "$FACTORY_DIR/test/py/run.py" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  FAILS=$(( FAILS + $(printf '%s\n' "$out" | grep -c '^  FAIL ') ))
  [ "$rc" = 0 ] || [ "$FAILS" -gt 0 ] || fail "$1: exited $rc without a FAIL line"
}
wait_for() {  # wait_for <what> <command...>: retry the command every 0.1 s until it succeeds; after TEST_WAIT_SECS (default 60) seconds, fail and return 1
  local what="$1" limit=$((SECONDS + ${TEST_WAIT_SECS:-60}))
  shift
  while ! "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$limit" ]; then fail "timed out waiting for $what"; return 1; fi
    sleep 0.1
  done
}
