#!/usr/bin/env bash
# #174: `shipfloor init [<repo>] [--yes]` takes a clean machine to a working factory in one guided run.
# git is real (on throwaway repos with a bare origin); gh, claude and the dispatcher installer are stand-ins.
source "$(dirname "$0")/lib.sh"
M_SRC="$FACTORY_DIR/shipfloor"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
REAL_PY="$(command -v "$FACTORY_PYTHON")"; export FACTORY_PYTHON="$REAL_PY"
ROOT="$(cd "$FACTORY_DIR/.." && pwd)"

# A plugin copy that is not a clone, with installer/ and examples/ too; the dispatcher installer is a stand-in that
# logs every call in $SF_ST/installer-calls and keeps "registered" as a file there.
PC="$(plugin_copy)"; mkdir -p "$PC/installer" "$PC/examples"
cp "$ROOT/examples/factory.yml" "$PC/examples/factory.yml"
cat > "$PC/installer/install-dispatcher.sh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$SF_ST/installer-calls"
case "${1:-}" in
  --status) [ -e "$SF_ST/registered" ] && { echo "registered: cron"; exit 0; }; echo "not registered"; exit 1 ;;
  --uninstall) rm -f "$SF_ST/registered" ;;
  *) touch "$SF_ST/registered" ;;
esac
exit 0
EOS
cat > "$PC/installer/install-dispatcher.ps1" <<'EOS'
exit 0
EOS
M="$PC/scripts/shipfloor"

mkgh() {  # mkgh <dir>: a gh stand-in; it logs its calls in $GH_STUB_DIR/calls and is signed out while $GH_STUB_DIR/noauth exists
  cat > "$1/gh" <<'EOS'
#!/usr/bin/env bash
d="$GH_STUB_DIR"; args="$*"
printf '%s\t%s\n' "$PWD" "$args" >> "$d/calls"
case "$args" in
  "auth status"*) [ -e "$d/noauth" ] && { echo "You are not logged in" >&2; exit 1; }; exit 0 ;;
  "api repos/"*"/protection"*) echo true ;;
  "repo view"*) echo acme/shop ;;
  "project view"*) echo PVT_x ;;
  "project field-list"*"| .id") echo FLD_x ;;
  "project field-list"*) i=0; for s in "👤 Inbox" "👤 Ready for Refinement" "🤖 Technical Refinement" "👤 Spec Review" "👤 Ready for Dev" "🤖 Coding" "🤖 Validation" "👤 Staged" "👤 Ready for Prod" "🤖 Done"; do i=$((i+1)); printf '%s\topt%s\n' "$s" "$i"; done ;;
  "project item-list"*group_by*) echo "Coding: 1" ;;
  "project item-list"*) printf 'I1\t🤖 Coding\n' ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$1/gh"
}

mkworld() {  # mkworld [noclaude]: a clean machine: its own home, gh/claude stand-ins, installer state
  WH="$(mktemp -d)"; SH="$WH/.shipfloor"; G="$(mktemp -d)"; ST="$(mktemp -d)"; GS="$(mktemp -d)"
  export GH_STUB_DIR="$G" SF_ST="$ST"
  mkgh "$GS"
  [ "${1:-}" = noclaude ] || { printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/claude"; chmod +x "$GS/claude"; }
  WPATH="$GS:$PATH"
}

mkrepo() {  # mkrepo: REPO (a clone named shop) with an empty-of-config origin/main in REMOTE
  REMOTE="$(mktemp -d)"; git init -q --bare "$REMOTE"
  REPO="$(mktemp -d)/shop"; mkdir "$REPO"; cp -r "$REPO_TEMPLATE/." "$REPO/"
  git -C "$REPO" remote add origin "$REMOTE"; git -C "$REPO" push -q origin main
}

mkrepo_cfg() {  # mkrepo_cfg: as mkrepo, with the fixture config already on origin/main
  mkrepo
  mkdir -p "$REPO/.shipfloor"; cp "$FACTORY_DIR/test/fixture/factory.yml" "$REPO/.shipfloor/factory.yml"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm cfg; git -C "$REPO" push -q origin main
}

init_run() {  # init_run <args...>: shipfloor init without a terminal; sets OUT and RC
  OUT="$(env HOME="$WH" SHIPFLOOR_HOME="$SH" PATH="${WPATH}" bash "$M" init "$@" </dev/null 2>&1)"; RC=$?
}
commits() { git -C "$REMOTE" rev-list --count main; }
installer_changes() { grep -vc -e '--status' "$ST/installer-calls" 2>/dev/null || true; }
sh_empty() { [ -z "$(find "$SH" -mindepth 1 2>/dev/null)" ]; }

# ---- AC-1: a clean machine, a repo without a config: init does every step and ends in doctor
mkworld; mkrepo
c0="$(commits)"; head0="$(git -C "$REPO" rev-parse HEAD)"
init_run "$REPO" --yes
[ "$RC" = 0 ] && pass "AC-1 init <repo> --yes exits 0" || fail "AC-1 init exits $RC: $OUT"
[ -f "$SH/factory/gate.sh" ] && [ -f "$SH/factory/shipfloor" ] && pass "AC-1 installed the factory" || fail "AC-1 the factory is not installed: $OUT"
git -C "$REMOTE" cat-file -e main:.shipfloor/factory.yml 2>/dev/null && pass "AC-1 factory.yml is on origin/main" || fail "AC-1 no .shipfloor/factory.yml on origin/main: $OUT"
assert_contains "$(git -C "$REMOTE" show main:.shipfloor/factory.yml 2>&1)" "name: shop"
[ "$(commits)" = "$((c0 + 1))" ] && pass "AC-1 exactly one commit pushed to main" || fail "AC-1 origin/main went from $c0 to $(commits) commits"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REMOTE" rev-parse main)" ] && [ "$(git -C "$REPO" rev-parse HEAD)" != "$head0" ] && pass "AC-1 the local main is the pushed commit" || fail "AC-1 local main is not origin/main"
[ -z "$(git -C "$REPO" status --porcelain)" ] && pass "AC-1 the clone is clean after the commit" || fail "AC-1 the clone has changes: $(git -C "$REPO" status --porcelain)"
assert_contains "$(cat "$SH/registry.tsv" 2>&1)" "shop	"
[ -d "$SH/projects/shop/control" ] && pass "AC-1 the project is added" || fail "AC-1 no control checkout"
assert_contains "$(cat "$G/calls")" "label create blocked --repo"
[ -e "$ST/registered" ] && [ "$(installer_changes)" = 1 ] && pass "AC-1 the dispatcher is registered once" || fail "AC-1 dispatcher calls: $(cat "$ST/installer-calls" 2>&1)"
assert_contains "$OUT" "ok   gh authenticated"
assert_contains "$OUT" "ok   project shop"
case "$OUT" in *FAIL*) fail "AC-1 a FAIL line in: $OUT" ;; *) pass "AC-1 no FAIL line" ;; esac
doctor_pos="$(printf '%s\n' "$OUT" | grep -n 'ok   gh authenticated' | head -1 | cut -d: -f1)"
last_step="$(printf '%s\n' "$OUT" | grep -nE '^ *\$ .*install-dispatcher' | head -1 | cut -d: -f1)"
[ -n "$doctor_pos" ] && [ -n "$last_step" ] && [ "$doctor_pos" -gt "$last_step" ] && pass "AC-1 doctor runs after the dispatcher step" || fail "AC-1 doctor is not the last step (doctor line $doctor_pos, dispatcher line $last_step)"

# ---- AC-6: every step shows the equivalent manual command
for pat in 'shipfloor install' 'shipfloor add ' 'setup-board shop' 'install-dispatcher' 'shipfloor doctor' 'git -C .* commit'; do
  printf '%s\n' "$OUT" | grep -qE "^ *\\$ .*$pat" && pass "AC-6 prints \$ <command> for $pat" || fail "AC-6 no '\$ ... $pat' line in: $OUT"
done

# ---- AC-2: a second run changes nothing and says what was already done
reg1="$(cat "$SH/registry.tsv")"; c1="$(commits)"; head1="$(git -C "$REPO" rev-parse HEAD)"; ic1="$(installer_changes)"
cfg1="$(git -C "$REMOTE" show main:.shipfloor/factory.yml)"
init_run "$REPO" --yes
[ "$RC" = 0 ] && pass "AC-2 the second run exits 0" || fail "AC-2 the second run exits $RC: $OUT"
[ "$(commits)" = "$c1" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$head1" ] && pass "AC-2 no new commit" || fail "AC-2 the second run committed"
[ "$(git -C "$REMOTE" show main:.shipfloor/factory.yml)" = "$cfg1" ] && pass "AC-2 factory.yml untouched" || fail "AC-2 factory.yml changed"
[ "$(cat "$SH/registry.tsv")" = "$reg1" ] && pass "AC-2 registry unchanged" || fail "AC-2 registry changed: $(cat "$SH/registry.tsv")"
[ "$(installer_changes)" = "$ic1" ] && pass "AC-2 the dispatcher is not registered again" || fail "AC-2 the installer ran again: $(cat "$ST/installer-calls")"
n="$(printf '%s\n' "$OUT" | grep -ci 'already')"
[ "$n" -ge 4 ] && pass "AC-2 says 'already' for the install, factory.yml, add and dispatcher steps ($n lines)" || fail "AC-2 only $n 'already' lines in: $OUT"
case "$OUT" in *FAIL*) fail "AC-2 a FAIL line in: $OUT" ;; *) pass "AC-2 no FAIL line" ;; esac

# ---- AC-3: a repo that already has .shipfloor/factory.yml keeps it; it is not generated nor committed
mkworld; mkrepo_cfg
c0="$(commits)"; cfg0="$(git -C "$REMOTE" show main:.shipfloor/factory.yml)"; head0="$(git -C "$REPO" rev-parse HEAD)"
init_run "$REPO" --yes
[ "$RC" = 0 ] && pass "AC-3 init --yes on a repo with a config exits 0" || fail "AC-3 exits $RC: $OUT"
[ "$(git -C "$REMOTE" show main:.shipfloor/factory.yml)" = "$cfg0" ] && pass "AC-3 the config is kept as it was" || fail "AC-3 the config changed"
[ "$(commits)" = "$c0" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$head0" ] && pass "AC-3 no commit" || fail "AC-3 init committed"
printf '%s\n' "$OUT" | grep -iE 'factory\.yml.*(kept|keep|already|exists)|(kept|keep|already|exists).*factory\.yml' >/dev/null && pass "AC-3 says the config is kept" || fail "AC-3 does not say it kept factory.yml: $OUT"
printf '%s\n' "$OUT" | grep -qE '^ *\$ git -C .* commit' && fail "AC-3 shows a commit command for a config that exists" || pass "AC-3 no commit step"
assert_contains "$(cat "$SH/registry.tsv" 2>&1)" "shop	"
# with no terminal and no --yes it is the same: the file is never overwritten without an explicit confirmation
init_run "$REPO"
[ "$(git -C "$REMOTE" show main:.shipfloor/factory.yml)" = "$cfg0" ] && [ "$(commits)" = "$c0" ] && pass "AC-3 without --yes the config is still not overwritten" || fail "AC-3 the config was overwritten without a confirmation"
[ "$(cat "$REPO/.shipfloor/factory.yml")" = "$cfg0" ] && pass "AC-3 the working copy is untouched too" || fail "AC-3 the working copy changed"

# ---- AC-4: a missing prerequisite stops init before it changes anything, names it and its fix
nothing_changed() {  # nothing_changed <what>
  sh_empty && [ ! -e "$SH/registry.tsv" ] && [ ! -e "$ST/installer-calls" ] && [ "$(commits)" = "$c0" ] && [ -z "$(git -C "$REPO" status --porcelain)" ] \
    && pass "AC-4 $1: nothing changed" || fail "AC-4 $1: something changed ($(find "$SH" -mindepth 1 2>/dev/null | head -3), $(git -C "$REPO" status --porcelain))"
}
mkworld; mkrepo; c0="$(commits)"; touch "$G/noauth"
init_run "$REPO" --yes
[ "$RC" -ne 0 ] && pass "AC-4 gh not authenticated: exits non-zero" || fail "AC-4 gh not authenticated: exit 0"
assert_contains "$OUT" "gh auth login"
nothing_changed "gh not authenticated"

mkworld noclaude; mkrepo; c0="$(commits)"
NB="$(mktemp -d)"
for t in bash env dirname basename uname mkdir rm cp cat id mktemp sed grep sort date readlink ls chmod mv tr cut head wc find stat; do
  p="$(command -v "$t")"; [ -n "$p" ] && ln -s "$p" "$NB/$t"
done
WPATH="$GS:$NB"; ln -s "$(command -v git)" "$NB/git"
init_run "$REPO" --yes   # control: claude absent from PATH is what the next lines test, on the same PATH
[ "$RC" -ne 0 ] && pass "AC-4 claude missing: exits non-zero" || fail "AC-4 claude missing: exit 0"
assert_contains "$OUT" "claude"
nothing_changed "claude missing"

mkworld; mkrepo; c0="$(commits)"
rm -f "$NB/git"
WPATH="$GS:$NB"
[ -z "$(PATH="$WPATH" command -v git)" ] && pass "AC-4 setup: git is off the PATH" || fail "AC-4 setup: git is still on the PATH ($(PATH="$WPATH" command -v git))"
init_run "$REPO" --yes
[ "$RC" -ne 0 ] && pass "AC-4 git missing: exits non-zero" || fail "AC-4 git missing: exit 0"
assert_contains "$OUT" "git"
sh_empty && [ ! -e "$SH/registry.tsv" ] && pass "AC-4 git missing: nothing installed" || fail "AC-4 git missing: init changed $SH"

# an old Python, and a Python without PyYAML: stand-in interpreters that run the real one with that one fact changed
oldpy="$(mktemp -d)/python3"; nopyyaml="$(mktemp -d)/python3"
printf '#!/usr/bin/env bash\nshift\nexec "%s" -I -c %s "$@"\n' "$REAL_PY" "'import sys,runpy; sys.version_info=(3,10,0,\"final\",0); f=sys.argv[1]; sys.argv=sys.argv[1:]; runpy.run_path(f, run_name=\"__main__\")'" > "$oldpy"
printf '#!/usr/bin/env bash\nshift\nexec "%s" -I -c %s "$@"\n' "$REAL_PY" "'import sys,runpy; sys.modules[\"yaml\"]=None; f=sys.argv[1]; sys.argv=sys.argv[1:]; runpy.run_path(f, run_name=\"__main__\")'" > "$nopyyaml"
chmod +x "$oldpy" "$nopyyaml"
mkworld; mkrepo; c0="$(commits)"
OUT="$(env FACTORY_PYTHON="$oldpy" HOME="$WH" SHIPFLOOR_HOME="$SH" PATH="$WPATH" bash "$M" init "$REPO" --yes </dev/null 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "AC-4 Python older than 3.11: exits non-zero" || fail "AC-4 old Python: exit 0: $OUT"
assert_contains "$OUT" "3.11"
nothing_changed "Python older than 3.11"
mkworld; mkrepo; c0="$(commits)"
OUT="$(env FACTORY_PYTHON="$nopyyaml" HOME="$WH" SHIPFLOOR_HOME="$SH" PATH="$WPATH" bash "$M" init "$REPO" --yes </dev/null 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "AC-4 PyYAML missing: exits non-zero" || fail "AC-4 no PyYAML: exit 0: $OUT"
assert_contains "$OUT" "pip install pyyaml"
nothing_changed "PyYAML missing"

# ---- AC-5: without <repo> init does the machine part only and touches no repository
mkworld; mkrepo
c0="$(commits)"; head0="$(git -C "$REPO" rev-parse HEAD)"
OUT="$(cd "$REPO" && env HOME="$WH" SHIPFLOOR_HOME="$SH" PATH="$WPATH" bash "$M" init --yes </dev/null 2>&1)"; RC=$?
[ "$RC" = 0 ] && pass "AC-5 init --yes without a repo exits 0" || fail "AC-5 exits $RC: $OUT"
[ -f "$SH/factory/gate.sh" ] && pass "AC-5 installed" || fail "AC-5 not installed: $OUT"
[ -e "$ST/registered" ] && pass "AC-5 registered the dispatcher" || fail "AC-5 no dispatcher: $OUT"
assert_contains "$OUT" "ok   gh authenticated"
[ ! -s "$SH/registry.tsv" ] && [ ! -e "$SH/projects/shop" ] && pass "AC-5 no project registered" || fail "AC-5 registered something: $(cat "$SH/registry.tsv" 2>&1)"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$head0" ] && [ "$(commits)" = "$c0" ] && [ -z "$(git -C "$REPO" status --porcelain)" ] && [ ! -e "$REPO/.shipfloor" ] && pass "AC-5 the repository (even the one it ran in) is untouched" || fail "AC-5 touched the repository"
case "$(cat "$G/calls")" in *"project view"*|*"label create"*) fail "AC-5 touched a board" ;; *) pass "AC-5 touched no board" ;; esac

# ---- AC-6: no terminal and no --yes: nothing destructive happens, the exact command is printed, exit 1
mkworld; mkrepo
c0="$(commits)"; head0="$(git -C "$REPO" rev-parse HEAD)"
init_run "$REPO"
[ "$RC" = 1 ] && pass "AC-6 without a terminal and without --yes it exits 1" || fail "AC-6 exits $RC: $OUT"
[ "$(commits)" = "$c0" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$head0" ] && pass "AC-6 no commit in the owner's repository" || fail "AC-6 init committed without a confirmation"
assert_contains "$OUT" "git -C"
assert_contains "$OUT" "$REPO"
printf '%s\n' "$OUT" | grep -E 'git -C' | grep -q 'commit' && pass "AC-6 prints the exact commit command" || fail "AC-6 no 'git -C ... commit' line: $OUT"
[ ! -s "$SH/registry.tsv" ] && pass "AC-6 the project is not added while the config is not on origin/main" || fail "AC-6 registered a project: $(cat "$SH/registry.tsv")"
# with --yes, a staged change that is not init's blocks the commit: init prints the command and stops
mkworld; mkrepo
c0="$(commits)"; head0="$(git -C "$REPO" rev-parse HEAD)"
echo mine > "$REPO/other.txt"; git -C "$REPO" add other.txt
init_run "$REPO" --yes
[ "$RC" -ne 0 ] && pass "AC-6 unrelated staged changes: init stops (exit $RC)" || fail "AC-6 unrelated staged changes: exit 0"
[ "$(commits)" = "$c0" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$head0" ] && pass "AC-6 unrelated staged changes: no commit" || fail "AC-6 init committed over staged changes"
[ "$(git -C "$REPO" diff --cached --name-only)" = other.txt ] && pass "AC-6 the owner's staged file stays staged and alone" || fail "AC-6 staging changed: $(git -C "$REPO" diff --cached --name-only)"
printf '%s\n' "$OUT" | grep -E 'git -C' | grep -q 'commit' && pass "AC-6 unrelated staged changes: prints the command" || fail "AC-6 no command printed: $OUT"

# ---- AC-7: the README quick start is init plus what remains; the manual steps live in docs/install.md
quick="$(awk '/^## Quick start/{f=1;next} /^## /{f=0} f' "$ROOT/README.md")"
assert_contains "$quick" "shipfloor init"
assert_contains "$quick" "docs/install.md"
for manual in 'cp examples/factory.yml' 'shipfloor add <repo>' 'shipfloor setup-board' 'claude plugin install'; do
  case "$quick" in *"$manual"*) fail "AC-7 the README quick start still lists the manual step '$manual'" ;; *) pass "AC-7 the quick start no longer lists '$manual'" ;; esac
done
inst="$(cat "$ROOT/docs/install.md")"
for manual in 'claude plugin install' 'shipfloor install' 'alias shipfloor=' 'examples/factory.yml' 'shipfloor add' 'shipfloor setup-board' 'install-dispatcher.sh' 'install-dispatcher.ps1'; do
  assert_contains "$inst" "$manual"
done
assert_contains "$inst" "shipfloor init"
finish
