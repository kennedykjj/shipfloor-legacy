#!/usr/bin/env bash
# The dashboard started directly (no SHIPFLOOR_BASH) picks its own shell: a usable bash, never the WSL launcher, or it refuses to start.
# lib.sh unsets every SHIPFLOOR_* variable, so every server here starts with SHIPFLOOR_BASH unset.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
PYABS="$(command -v $PY)"
W="$(mktemp -d)"; srv=""; trap 'kill $srv 2>/dev/null' EXIT
DASH="$(nat "$FACTORY_DIR/dashboard.py")"; SFDIR="$(nat "$FACTORY_DIR")"

# ---- find_bash(environ, windows), called from Python -------------------------------------------------------
# fb WINDOWS KIND EXPECTED KEY=VAL...  (a "|" in a value is the PATH separator of the machine; KIND: none | dir | exact)
cat > "$W/fb.py" <<'PYEOF'
import os, sys
sys.path.insert(0, sys.argv[1])
windows = sys.argv[2] == "1"; kind, expected = sys.argv[3], sys.argv[4]
environ = {}
for kv in sys.argv[5:]:
    k, v = kv.split("=", 1)
    environ[k] = os.pathsep.join(v.split("|")) if k == "PATH" else v
try:
    import dashboard
except BaseException as e:
    print("FAIL: dashboard.py cannot be imported: %r" % (e,)); sys.exit(0)
if not hasattr(dashboard, "find_bash"):
    print("FAIL: dashboard.py has no find_bash(environ, windows): the shell is still chosen by a bare bash fallback"); sys.exit(0)
got = dashboard.find_bash(environ, windows)
norm = lambda p: os.path.normcase(os.path.normpath(p))
if kind == "none":
    print("OK" if got is None else "FAIL: find_bash returned %r, want None (no usable bash)" % (got,))
elif kind == "dir":
    ok = got is not None and norm(os.path.dirname(got)) == norm(expected)
    print("OK" if ok else "FAIL: find_bash returned %r, want a bash in %s" % (got, expected))
else:
    print("OK" if got == expected else "FAIL: find_bash returned %r, want exactly %r" % (got, expected))
PYEOF
fb() { $PY -I "$(nat "$W/fb.py")" "$SFDIR" "$@"; }
check() {  # check LABEL OUTPUT
  case "$2" in OK) pass "$1" ;; *) fail "$1: ${2:-no output}" ;; esac
}

mkbash() { mkdir -p "$1"; for f in bash bash.exe; do printf '#!/bin/sh\nexit 0\n' > "$1/$f"; chmod +x "$1/$f"; done; }
SR="$W/Windows"; S32="$SR/System32"; WA="$W/Local/Microsoft/WindowsApps"; GIT="$W/Git/bin"; EMPTY="$W/empty"
mkbash "$S32"; mkbash "$WA"; mkbash "$GIT"; mkdir -p "$EMPTY"
WINENV=("SystemRoot=$(nat "$SR")" "LOCALAPPDATA=$(nat "$W/Local")")

# AC-3: the only bash found is the WSL launcher: nothing is returned
check "AC-3 System32 bash is refused on Windows" "$(fb 1 none "" "${WINENV[@]}" "PATH=$(nat "$S32")")"
check "AC-3 WindowsApps bash is refused on Windows" "$(fb 1 none "" "${WINENV[@]}" "PATH=$(nat "$WA")")"
check "AC-3 System32 spelled in another case and with a dot segment is refused" "$(fb 1 none "" "SystemRoot=$(nat "$SR" | tr a-z A-Z | sed 's#/#/./#')" "LOCALAPPDATA=$(nat "$W/Local")" "PATH=$(nat "$S32" | tr A-Z a-z)")"

# AC-4: nothing at all
check "AC-4 no bash on PATH gives no shell" "$(fb 1 none "" "${WINENV[@]}" "PATH=$(nat "$EMPTY")")"
check "AC-4 no bash on PATH gives no shell (not Windows)" "$(fb 0 none "" "PATH=$(nat "$EMPTY")")"

# AC-1: a WSL bash earlier in PATH is skipped, the next one wins
check "AC-1 System32 first, Git bash second: Git bash" "$(fb 1 dir "$(nat "$GIT")" "${WINENV[@]}" "PATH=$(nat "$S32")|$(nat "$GIT")")"
check "AC-1 WindowsApps and System32 first, Git bash last: Git bash" "$(fb 1 dir "$(nat "$GIT")" "${WINENV[@]}" "PATH=$(nat "$WA")|$(nat "$S32")|$(nat "$GIT")")"
check "AC-1 the first usable bash wins, in PATH order" "$(fb 1 dir "$(nat "$GIT")" "${WINENV[@]}" "PATH=$(nat "$GIT")|$(nat "$S32")")"

# AC-6: SHIPFLOOR_BASH is taken as given: no lookup, no check, not refused
check "AC-6 SHIPFLOOR_BASH that does not exist, empty PATH: returned as is" "$(fb 0 exact "/no/such/shell/bash" SHIPFLOOR_BASH=/no/such/shell/bash "PATH=")"
check "AC-6 SHIPFLOOR_BASH that does not exist, Windows: returned as is" "$(fb 1 exact "/no/such/shell/bash" "${WINENV[@]}" SHIPFLOOR_BASH=/no/such/shell/bash "PATH=")"
check "AC-6 SHIPFLOOR_BASH inside System32, Windows: not refused" "$(fb 1 exact "$(nat "$S32")/bash.exe" "${WINENV[@]}" "SHIPFLOOR_BASH=$(nat "$S32")/bash.exe" "PATH=$(nat "$GIT")")"
check "AC-6 SHIPFLOOR_BASH wins over a bash on PATH" "$(fb 1 exact "/my/own/bash" "${WINENV[@]}" SHIPFLOOR_BASH=/my/own/bash "PATH=$(nat "$GIT")")"

# AC-7: not Windows: a directory named System32 means nothing
UX="$W/unix/System32"; mkbash "$UX"
check "AC-7 not Windows: a bash in a directory named System32 is returned" "$(fb 0 dir "$(nat "$UX")" "PATH=$(nat "$UX")")"
check "AC-7 not Windows: the fake System32 under SystemRoot is not refused" "$(fb 0 dir "$(nat "$S32")" "${WINENV[@]}" "PATH=$(nat "$S32")|$(nat "$GIT")")"

# ---- the server, started directly --------------------------------------------------------------------------
H="$SHIPFLOOR_HOME"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
export FAKE_GH_DIR="$W/gh"; mkdir -p "$FAKE_GH_DIR"
export FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 CLAUDE_CONFIG_DIR="$(nat "$(mktemp -d)")"
unset SHIPFLOOR_BASH

# AC-4/AC-5: no bash anywhere (PATH is one empty directory, Python by its absolute path): it refuses at start
OUT="$W/ref.out"; ERR="$W/ref.err"
env PATH="$EMPTY" "$PYABS" -I "$DASH" --home "$(nat "$H")" --port 0 --no-open > "$OUT" 2> "$ERR" &
srv=$!
for _ in $(seq 1 50); do kill -0 $srv 2>/dev/null || break; grep -qs 'http://' "$OUT" && break; sleep 0.1; done
if kill -0 $srv 2>/dev/null; then
  kill $srv 2>/dev/null; sleep 0.3; kill -9 $srv 2>/dev/null
  fail "AC-4 the server started instead of refusing: no bash on PATH and SHIPFLOOR_BASH unset (out: $(head -c 200 "$OUT"))"
  fail "AC-5 the server started instead of exiting: no exit code, no refusal line"
  fail "AC-4 a URL was printed although no bash was found"
else
  wait $srv; rc=$?
  [ "$rc" -ne 0 ] && pass "AC-4 exits non-zero when no bash is found ($rc)" || fail "AC-4 exited 0 when no bash is found"
  ! grep -qs 'http://' "$OUT" "$ERR" && pass "AC-4 no URL printed, nothing served" || fail "AC-4 a URL was printed although no bash was found"
  [ "$(wc -l < "$ERR" | tr -d ' ')" = 1 ] && pass "AC-5 stderr is one line" || fail "AC-5 stderr is not one line: $(cat "$ERR")"
  assert_contains "$(cat "$ERR")" "SHIPFLOOR_BASH"
  assert_contains "$(cat "$ERR")" "shipfloor dashboard"
fi
srv=""

# AC-1/AC-2/AC-7: the test's own PATH, SHIPFLOOR_BASH unset: titles are read, an approve moves the card
$PY -I "$DASH" --home "$(nat "$H")" --port 0 --no-open > "$W/ok.out" 2>&1 &
srv=$!
for _ in $(seq 1 50); do grep -qs 'http://' "$W/ok.out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$W/ok.out")"
if [ -z "$url" ]; then
  fail "AC-7 the server did not start with a bash on PATH and SHIPFLOOR_BASH unset: $(head -c 300 "$W/ok.out")"
else
  pass "AC-7 starts with a bash on PATH and SHIPFLOOR_BASH unset"
  base="${url%%/?t=*}"; tok="${url##*t=}"; H_TOK="X-Shipfloor-Token: $tok"
  got="$(curl -s -H "$H_TOK" "$base/api/card/shop/7" | $PY -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
  case "$got" in "Seven") pass "AC-1 the card shows its issue title" ;; *) fail "AC-1 title is '$got', want 'Seven'" ;; esac
  printf 'PVTI_7\t7\t👤 Spec Review\n' > "$FAKE_GH_DIR/items.tsv"
  c="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d '{"column":"Spec Review"}' "$base/api/card/shop/7/approve")"
  [ "$c" = 200 ] && pass "AC-2 approve answers 200" || fail "AC-2 approve answered $c, want 200"
  assert_contains "$(cat "$FAKE_GH_DIR/edits" 2>/dev/null)" "--id PVTI_7 --field-id FLD_x --single-select-option-id opt5"
fi
kill $srv 2>/dev/null; srv=""

finish
