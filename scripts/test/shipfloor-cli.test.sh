#!/usr/bin/env bash
# The shipfloor CLI installs the scripts and manages the project registry.
source "$(dirname "$0")/lib.sh"
M="$FACTORY_DIR/shipfloor"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export SHIPFLOOR_HOME="$(mktemp -d)"

with_config() {  # with_config <yaml>: a repo whose origin/main carries that config
  local remote r; remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.shipfloor"; printf '%s\n' "$1" > "$r/.shipfloor/factory.yml"
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  echo "$r"
}

# install copies the scripts and templates to a fixed place, without the tests
assert_exit 0 bash "$(plugin_copy)/scripts/shipfloor" install
for f in gate.sh board.sh dispatch.sh shipfloor-dispatch.sh shipfloor-config.sh shipfloor_config.py lib/project.sh shipfloor templates/spec-template.md; do
  [ -f "$SHIPFLOOR_HOME/factory/$f" ] && pass "installed $f" || fail "missing $f"
done
[ ! -e "$SHIPFLOOR_HOME/factory/test" ] && pass "tests not installed" || fail "installed the tests"

r="$(with_config "$(cat "$FACTORY_DIR/test/fixture/factory.yml")")"
assert_exit 0 bash "$M" add "$r"
assert_contains "$(cat "$SHIPFLOOR_HOME/registry.tsv")" "shop	$(git -C "$r" rev-parse --show-toplevel)	$SHIPFLOOR_HOME/projects/shop/wt	main"
[ -f "$SHIPFLOOR_HOME/projects/shop/control/.shipfloor/factory.yml" ] && pass "control checkout" || fail "no control checkout"
[ -f "$SHIPFLOOR_HOME/projects/shop/factory.yml" ] && pass "config snapshot" || fail "no config snapshot"
assert_exit 0 bash "$M" add "$r"
[ "$(grep -c '^shop	' "$SHIPFLOOR_HOME/registry.tsv")" = 1 ] && pass "add is idempotent" || fail "duplicated the project"
wt="$(mktemp -d)"; assert_exit 0 bash "$M" add "$r" --worktrees "$wt"
assert_contains "$(cat "$SHIPFLOOR_HOME/registry.tsv")" "$wt"

# add again without --worktrees keeps the registered worktrees and reads the config from the new origin/main
sed -i 's/^\(  name: shop\)$/\1 # v2/' "$r/.shipfloor/factory.yml"
git -C "$r" commit -qam v2; git -C "$r" push -q origin main
assert_exit 0 bash "$M" add "$r"
assert_contains "$(cat "$SHIPFLOOR_HOME/registry.tsv")" "shop	$(git -C "$r" rev-parse --show-toplevel)	$wt	main"
assert_contains "$(cat "$SHIPFLOOR_HOME/projects/shop/factory.yml")" "# v2"

# another repo cannot take a registered name
other="$(with_config "$(cat "$FACTORY_DIR/test/fixture/factory.yml")")"
assert_exit 1 bash "$M" add "$other"

bad="$(with_config 'project: {name: bad}')"
assert_exit 1 bash "$M" add "$bad"
case "$(cat "$SHIPFLOOR_HOME/registry.tsv")" in *bad*) fail "registered an invalid config" ;; *) pass "invalid config not registered" ;; esac
noconf="$(new_repo)"; assert_exit 1 bash "$M" add "$noconf"

assert_contains "$(bash "$M" list)" "shop"
assert_exit 0 bash "$M" pause shop; [ -e "$SHIPFLOOR_HOME/projects/shop/PAUSE" ] && pass "pause one" || fail "no project PAUSE"
assert_contains "$(bash "$M" list)" "paused"
assert_exit 0 bash "$M" resume shop; [ ! -e "$SHIPFLOOR_HOME/projects/shop/PAUSE" ] && pass "resume one" || fail "PAUSE left"
assert_exit 0 bash "$M" pause; [ -e "$SHIPFLOOR_HOME/PAUSE" ] && pass "pause all" || fail "no global PAUSE"
assert_exit 0 bash "$M" resume; [ ! -e "$SHIPFLOOR_HOME/PAUSE" ] && pass "resume all" || fail "global PAUSE left"
assert_exit 1 bash "$M" pause nope

assert_exit 0 bash "$M" remove shop
case "$(cat "$SHIPFLOOR_HOME/registry.tsv")" in *shop*) fail "still registered" ;; *) pass "removed" ;; esac
[ ! -e "$SHIPFLOOR_HOME/projects/shop/control" ] && pass "control checkout removed" || fail "control left behind"
assert_exit 1 bash "$M" remove shop
assert_exit 2 bash "$M" nonsense

# the machine pool
assert_contains "$(bash "$M" pool)" "pool: 4"
assert_exit 0 bash "$M" pool set 6
assert_exit 0 bash "$M" pool stage validate 3
out="$(bash "$M" pool)"; assert_contains "$out" "pool: 6"; assert_contains "$out" "validate: 3"
mkdir -p "$SHIPFLOOR_HOME/projects/a/locks/validate-7.lock"; echo "$$ $(date +%s) 7" > "$SHIPFLOOR_HOME/projects/a/locks/validate-7.lock/info"
assert_contains "$(bash "$M" pool)" "validate: 3 (1 running)"
assert_exit 1 bash "$M" pool stage validate 9
assert_exit 1 bash "$M" pool stage review 1
assert_contains "$(bash "$M" pool)" "validate: 3"

# AC-3: doctor says nothing about a leftover ~/.aghanim and leaves it alone
fake="$(mktemp -d)"; mkdir -p "$fake/.aghanim"; echo keep > "$fake/.aghanim/marker"
out="$(HOME="$fake" SHIPFLOOR_HOME="$fake/.shipfloor" bash "$M" doctor 2>&1)"
case "$out" in *[Aa]ghanim*|*migrate-home*) fail "AC-3 doctor still warns about ~/.aghanim: $out" ;; *) pass "AC-3 doctor has no warning about ~/.aghanim" ;; esac
[ "$(cat "$fake/.aghanim/marker" 2>/dev/null)" = keep ] && [ ! -e "$fake/.shipfloor" -o -d "$fake/.shipfloor" ] && pass "AC-3 the ~/.aghanim directory is untouched" || fail "AC-3 doctor touched ~/.aghanim"

# AC-2: migrate-home is gone: unknown command (exit 2), not in help
assert_exit 2 bash "$M" migrate-home
help_out="$(bash "$M" help 2>&1; bash "$M" 2>&1 || true)"
case "$help_out" in *migrate-home*) fail "AC-2 help still lists migrate-home" ;; *) pass "AC-2 help does not list migrate-home" ;; esac
# the usage is the script's header, so the header and the command table must not carry it either
grep -q 'migrate-home' "$M" && fail "AC-2 scripts/shipfloor still mentions migrate-home: $(grep -n 'migrate-home' "$M" | head -3)" || pass "AC-2 scripts/shipfloor no longer mentions migrate-home"

# clean removes tmp/<n>/ of cards that are Done or off the board, and keeps the active ones
assert_exit 0 bash "$M" add "$r"
H2="$SHIPFLOOR_HOME/projects/shop"; mkdir -p "$H2/tmp/5/x" "$H2/tmp/6/x" "$H2/tmp/8/x"
printf '5	Done	I5
6	Coding	I6
' > "$H2/board.tsv"
assert_contains "$(bash "$M" doctor 2>&1)" "shipfloor clean shop"
# doctor names a project the dispatcher skips, and a control checkout behind origin/main
printf '2026-10-09T20:06:50-03:00\tcannot bring the control checkout to origin/main: index.lock exists\n' > "$H2/SKIPPED"
out="$(bash "$M" doctor 2>&1)"; assert_contains "$out" "shop: the dispatcher skips it since 2026-10-09T20:06:50"
assert_contains "$out" "index.lock exists"
rm "$H2/SKIPPED"; git -C "$r" commit -q --allow-empty -m ahead; git -C "$r" push -q origin HEAD:main
assert_contains "$(bash "$M" doctor 2>&1)" "shop: control checkout is behind origin/main"
assert_exit 0 bash "$M" clean shop
[ ! -e "$H2/tmp/5" ] && [ ! -e "$H2/tmp/8" ] && [ -d "$H2/tmp/6" ] && pass "clean keeps the active card" || fail "clean removed the wrong tmp dirs: $(ls "$H2/tmp")"
# accept: the owner records the acceptance files of a card as reviewed, with a reason, and the gate takes them
W="$(mktemp -d)/9"; git -C "$r" worktree add -q -b feat/9-x "$W" main; mkdir -p "$W/api/src/test"
echo qa > "$W/api/src/test/NineTest.kt"; git -C "$W" add -A; git -C "$W" commit -qm "test(x): acceptance tests for #9"
qa9="$(git -C "$W" rev-parse HEAD)"
echo resolved > "$W/api/src/test/NineTest.kt"; git -C "$W" commit -qam "merge resolved by hand"
sed -i "s#^shop\t\([^\t]*\)\t[^\t]*#shop\t\1\t$(dirname "$W")#" "$SHIPFLOOR_HOME/registry.tsv"
assert_exit 2 bash "$M" accept shop 9
assert_exit 1 bash "$FACTORY_DIR/gate.sh" -C "$W" acceptance-intact "$qa9"
out="$(bash "$M" accept shop 9 main reworded the setup 2>&1)"; assert_contains "$out" "api/src/test/NineTest.kt"
assert_contains "$(cat "$H2/accepted.tsv")" "main reworded the setup"
assert_exit 0 bash "$FACTORY_DIR/gate.sh" -C "$W" acceptance-intact "$qa9"
assert_contains "$(bash "$M" accept shop 9 again 2>&1)" "nothing to accept"
# accept also records a file the card deleted after the QA commit (a stub the real code replaced)
echo stub > "$W/api/src/test/RedStubs.kt"; git -C "$W" add -A; git -C "$W" commit -qm "test(x): acceptance tests for #9"
qa9="$(git -C "$W" rev-parse HEAD)"
git -C "$W" rm -q api/src/test/RedStubs.kt; git -C "$W" commit -qm "the real class replaces the stub"
assert_exit 1 bash "$FACTORY_DIR/gate.sh" -C "$W" acceptance-intact "$qa9"
assert_contains "$(bash "$M" accept shop 9 stub replaced 2>&1)" "accepted the deletion of api/src/test/RedStubs.kt"
assert_exit 0 bash "$FACTORY_DIR/gate.sh" -C "$W" acceptance-intact "$qa9"
assert_contains "$(bash "$M" accept shop 9 again 2>&1)" "nothing to accept"
# pool shows the stack slots
out="$(bash "$M" pool)"; assert_contains "$out" "stacks: 3"; assert_contains "$out" "slot 0: free"
# the first registered project ("shop") starts no stack of its own, yet the machine's 3 slots are listed
assert_contains "$out" "slot 1: free"; assert_contains "$out" "slot 2: free"

# AC-8: doctor says whether a dispatcher is registered and by which mechanism; the machine is faked by stand-ins
SRC="$(cd "$FACTORY_DIR/.." && pwd)"; ST="$(mktemp -d)"; SB="$(mktemp -d)"; export SF_ST="$ST" SF_REAL_UNAME="$(command -v uname)"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -s ]; then echo "${SF_UNAME:-Linux}"; else exec "$SF_REAL_UNAME" "$@"; fi\n' > "$SB/uname"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/systemctl"
printf '#!/usr/bin/env bash\ncase "${1:-}" in -l) [ -f "$SF_ST/table" ] && { cat "$SF_ST/table"; exit 0; }; exit 1 ;; -) cat > "$SF_ST/table" ;; esac\n' > "$SB/crontab"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/launchctl"
chmod +x "$SB/uname" "$SB/systemctl" "$SB/crontab" "$SB/launchctl"
dh="$(mktemp -d)"
out="$(HOME="$dh" PATH="$SB:$PATH" SF_UNAME=Linux bash "$M" doctor 2>&1)"
assert_contains "$out" "WARN no dispatcher registered; run: bash $SRC/installer/install-dispatcher.sh"
printf '*/3 * * * * /usr/bin/bash -l %s/factory/run-dispatcher.sh # shipfloor-dispatcher\n' "$SHIPFLOOR_HOME" > "$ST/table"
out="$(HOME="$dh" PATH="$SB:$PATH" SF_UNAME=Linux bash "$M" doctor 2>&1)"
assert_contains "$out" "ok   dispatcher registered (cron)"
case "$out" in *"no dispatcher registered"*) fail "AC-8 doctor warns of no dispatcher while the crontab holds one" ;; *) pass "AC-8 a registered dispatcher draws no warning" ;; esac
# the warning does not change doctor's exit code
rm -f "$ST/table"
a="$(HOME="$dh" PATH="$SB:$PATH" SF_UNAME=Linux bash "$M" doctor >/dev/null 2>&1; echo $?)"
printf '*/3 * * * * /usr/bin/bash -l x # shipfloor-dispatcher\n' > "$ST/table"
b="$(HOME="$dh" PATH="$SB:$PATH" SF_UNAME=Linux bash "$M" doctor >/dev/null 2>&1; echo $?)"
[ "$a" = "$b" ] && pass "AC-8 the missing-dispatcher warning leaves doctor's exit code alone" || fail "AC-8 doctor exits $a without a dispatcher and $b with one"
# on Windows doctor stays as it is
out="$(HOME="$dh" PATH="$SB:$PATH" SF_UNAME=MINGW64_NT-10.0 bash "$M" doctor 2>&1)"
case "$out" in *"dispatcher registered"*) fail "AC-8 doctor on Windows talks about the Linux/macOS dispatcher: $out" ;; *) pass "AC-8 doctor on Windows prints no dispatcher line" ;; esac
# the "next:" line of install names the command of the system it runs on
ih="$(mktemp -d)"
pc="$(plugin_copy)"  # a copy that is not a clone: install refuses a clone that is not a clean main (#80)
out="$(SHIPFLOOR_HOME="$ih" PATH="$SB:$PATH" SF_UNAME=Linux bash "$pc/scripts/shipfloor" install 2>&1)"
assert_contains "$out" "install-dispatcher.sh"
out="$(SHIPFLOOR_HOME="$ih" PATH="$SB:$PATH" SF_UNAME=Darwin bash "$pc/scripts/shipfloor" install 2>&1)"
assert_contains "$out" "install-dispatcher.sh"
out="$(SHIPFLOOR_HOME="$ih" PATH="$SB:$PATH" SF_UNAME=MINGW64_NT-10.0 bash "$pc/scripts/shipfloor" install 2>&1)"
assert_contains "$out" "install-dispatcher.ps1"
# the README names the install and uninstall command next to the Windows one
readme="$(cat "$SRC/README.md")"
assert_contains "$readme" "install-dispatcher.ps1"
assert_contains "$readme" "install-dispatcher.sh"
assert_contains "$readme" "install-dispatcher.sh --uninstall"
case "$readme" in *[Ll]inger*) pass "README explains lingering" ;; *) fail "README does not mention lingering for the Linux dispatcher" ;; esac
case "$readme" in *"PATH changes"*) pass "README says to run the installer again after PATH changes" ;; *) fail "README does not say to run the installer again after your PATH changes" ;; esac
case "$readme" in *macOS*) pass "README names macOS" ;; *) fail "README does not name macOS" ;; esac
finish
