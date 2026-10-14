#!/usr/bin/env bash
# AC-5 of #165: the Python scope and forbidden gates see the same changed set as the Bash ones (committed renames count
# both paths, uncommitted changes, untracked files that are not ignored, names never C-quoted) and match it with the
# ERE from shipfloor_config.py as before. A control character in a name blocks; scope's own check runs before
# forbidden's control-character check.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
pygate() { "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate "$@"; }
pygate --help >/dev/null 2>&1 || { fail "AC-5 the Python gate is missing: 'sf.py gate --help' fails, so scope and forbidden see no changed set"; exit 1; }

expect() {  # expect <label> <exit wanted> <gate args...>: sets ERR to the stderr
  local label="$1" want="$2" got; shift 2
  pygate "$@" >/dev/null 2>"$T/err"; got=$?; ERR="$(cat "$T/err")"
  case "$ERR" in "usage: sf.py"*) fail "AC-5 $label: sf.py has no gate command"; return 1 ;; esac
  if [ "$got" = "$want" ]; then pass "AC-5 $label"; else fail "AC-5 $label: python gate exit $got, want $want: $ERR"; return 1; fi
}
has() {  # has <label> <text>: the last stderr (ERR) has the text
  case "$ERR" in *"$2"*) pass "AC-5 $1" ;; *) fail "AC-5 $1: no '$2' in: $ERR" ;; esac
}
hasnot() {
  case "$ERR" in *"$2"*) fail "AC-5 $1: '$2' in: $ERR" ;; *) pass "AC-5 $1" ;; esac
}

fresh() { r="$(new_repo)"; cd "$r"; mkdir -p api/src/main web .github; printf 'ignored.log\n' > .gitignore; echo x > api/src/main/Keep.kt; git add -A; git commit -qm c; base="$(git rev-parse HEAD)"; }

# ---- uncommitted, untracked, ignored
fresh
echo changed >> api/src/main/Keep.kt
expect "an uncommitted edit is in the changed set (scope api passes)" 0 scope api "$base"
expect "an uncommitted edit is outside web's area (scope web blocks)" 1 scope web "$base" && has "scope names the uncommitted file" "api/src/main/Keep.kt"
git checkout -q -- .
echo x > api/src/main/New.kt
expect "an untracked file is in the changed set (scope web blocks)" 1 scope web "$base" && has "scope names the untracked file" "api/src/main/New.kt"
rm api/src/main/New.kt; echo x > ignored.log
expect "an untracked file that is ignored is not in the changed set" 0 scope po "$base"
expect "an ignored file does not trip forbidden" 0 forbidden "$base"
rm ignored.log
echo x > .github/w.yml
expect "an untracked forbidden file blocks" 1 forbidden "$base" && has "forbidden names the file" ".github/w.yml"
git add -A
expect "a staged forbidden file blocks" 1 forbidden "$base"
git commit -qm gh
expect "a committed forbidden file blocks" 1 forbidden "$base"
echo y >> .github/w.yml
expect "committed and uncommitted: still one block" 1 forbidden "$base"
n="$(printf '%s\n' "$ERR" | grep -c '^\.github/w\.yml$')"
[ "$n" = 1 ] && pass "AC-5 a file changed both ways is listed once" || fail "AC-5 listed $n times: $ERR"
git checkout -q -- .
git rm -q -r .github; git commit -qm "gh gone"
expect "a file added and deleted since the base is no change that is forbidden" 0 forbidden "$base"
expect "a file added then deleted leaves a clean scope for po" 0 scope po "$base"

# ---- renames: both paths count, committed or not
fresh; git mv api/src/main/Keep.kt web/Keep.kt
expect "an uncommitted rename api -> web: scope api blocks on the new path" 1 scope api "$base" && has "scope names the new path" "web/Keep.kt"
expect "an uncommitted rename api -> web: scope web blocks on the old path" 1 scope web "$base" && has "scope names the old path" "api/src/main/Keep.kt"
git commit -qm rename
expect "a committed rename: scope api blocks on the new path" 1 scope api "$base" && has "scope names the new path (committed)" "web/Keep.kt"
expect "a committed rename: scope web blocks on the old path" 1 scope web "$base" && has "scope names the old path (committed)" "api/src/main/Keep.kt"
fresh; echo x > .github/ci.yml; git add -A; git commit -qm ci; base2="$(git rev-parse HEAD)"; git mv .github/ci.yml api/ci.yml
expect "a rename out of .github: forbidden blocks on the old path" 1 forbidden "$base2" && has "forbidden names the old path" ".github/ci.yml"
expect "a rename out of .github: scope api blocks on the old path" 1 scope api "$base2" && has "scope names the old path" ".github/ci.yml"
git commit -qm "move ci"
expect "a committed rename out of .github: forbidden blocks" 1 forbidden "$base2"

# ---- names are never C-quoted
fresh; mkdir -p web/lib; echo x > "web/lib/ação.ts"
expect "a non-ASCII name outside the area blocks" 1 scope api "$base" && has "the non-ASCII name is listed as is (quotePath=false)" "web/lib/ação.ts"
hasnot "the name is not C-quoted" '\303'
rm "web/lib/ação.ts"; echo x > "api/src/main/ação.kt"
expect "a non-ASCII name inside the area passes" 0 scope api "$base"
expect "a non-ASCII name passes forbidden" 0 forbidden "$base"
echo x > "api/src/main/a+b (1) [x].kt"; echo x > "api/src/main/my file.kt"
expect "regex metacharacters and spaces in names are plain characters" 0 scope api "$base"

# ---- the ERE: anchored areas, forbidden prefixes
fresh; mkdir -p xapi docs/engineering docs/engineeringX apix; echo x > xapi/A.kt
expect "an area is anchored at the start of the path (xapi/ is not api/)" 1 scope api "$base" && has "xapi/A.kt is named" "xapi/A.kt"
rm -rf xapi; echo x > docs/engineering/a.md
expect "docs/engineering/ (the config's forbidden) blocks" 1 forbidden "$base" && has "docs/engineering/a.md is named" "docs/engineering/a.md"
rm docs/engineering/a.md; echo x > docs/engineeringX/a.md
expect "docs/engineeringX/ is not docs/engineering/" 0 forbidden "$base"
rm -rf docs; mkdir -p api web; echo x > api/.env; echo x > web/.env.local
expect "api/.env blocks" 1 forbidden "$base" && has "api/.env is named" "api/.env"
rm api/.env web/.env.local; echo x > api/env.kt
expect "api/env.kt is not an env file" 0 forbidden "$base"
echo x > web/e2e.txt
expect "tests-only layer: web/e2e.txt is not under web/e2e/" 1 scope api "$base" && has "web/e2e.txt is outside api" "web/e2e.txt"

# ---- control characters
fresh; nl="api/src/main/odd"$'\n'"name.kt"; echo x > "$nl"
expect "a newline in a name (inside the area) blocks in forbidden" 1 forbidden "$base" && has "forbidden says control character" "a changed file name has a control character"
expect "a newline in a name (inside the area): scope api blocks first, on the half-name the line split leaves" 1 scope api "$base" && { has "scope reports the area breach, not the control character" "scope: api touched files outside its area:"; hasnot "scope api has not reached forbidden's check" "a changed file name has a control character"; }
expect "a newline in a name: scope po blocks" 1 scope po "$base"
rm "$nl"; tb="api/src/main/tab"$'\t'"name.kt"; echo x > "$tb"
expect "a tab in a name blocks" 1 forbidden "$base" && has "a tab is a control character" "a changed file name has a control character"
expect "a tab in a name inside the area: scope api passes its own check and forbidden's blocks" 1 scope api "$base" && has "scope api reaches forbidden's control-character check" "a changed file name has a control character"
rm "$tb"; del="api/src/main/del"$'\177'"name.kt"; echo x > "$del"
expect "a DEL in a name blocks" 1 forbidden "$base" && has "DEL is a control character" "a changed file name has a control character"
rm "$del"
# scope's own check comes first: an odd name outside the area is reported by scope, not by the control-character check
nl="web/odd"$'\n'"name.ts"; echo x > "$nl"
expect "a newline in a name outside the area: scope api blocks" 1 scope api "$base" && { has "scope reports the area breach first" "scope: api touched files outside its area:"; hasnot "scope has not reached forbidden's control-character check" "a changed file name has a control character"; }
rm "$nl"
# a committed odd name counts too
nl="api/src/main/odd"$'\n'"name.kt"; echo x > "$nl"; git add -A; git commit -qm odd
expect "a committed name with a newline blocks" 1 forbidden "$base" && has "forbidden says control character (committed)" "a changed file name has a control character"
expect "the base itself at HEAD: nothing changed, the odd name is not in the set" 0 forbidden HEAD
finish
