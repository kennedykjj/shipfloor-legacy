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
# AC-8 (#129): doctor says the language each project writes in and where it comes from: the repository, or this machine
assert_contains "$(bash "$M" doctor 2>&1)" "ok   shop: writes in English (en), from the repository"
printf 'language: pt-BR\n' > "$H2/overrides.yml"
assert_contains "$(FACTORY_LANGUAGE=en bash "$M" doctor 2>&1)" "ok   shop: writes in Brazilian Portuguese (pt-BR), from this machine"
rm "$H2/overrides.yml"
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

# ---- #161 (PY-08): pins what the shipfloor CLI does today. "shop" is registered (re-added above) and its control checkout exists.
# A stand-in gh on PATH (setup-board.sh, doctor and the board scripts call `gh` by name): it records every call with the folder it ran in.
G="$(mktemp -d)"; GS="$(mktemp -d)"; export GH_STUB_DIR="$G"
cat > "$GS/gh" <<'EOS'
#!/usr/bin/env bash
d="$GH_STUB_DIR"; args="$*"
printf '%s\t%s\n' "$PWD" "$args" >> "$d/calls"
case "$args" in
  "auth status"*) [ -e "$d/noauth" ] && { echo "You are not logged in" >&2; exit 1; }; exit 0 ;;
  "api repos/acme/shop/branches/main/protection"*) cat "$d/protection"; [ -e "$d/protection-fails" ] && exit 1; exit 0 ;;
  "project view"*) echo PVT_x ;;
  "project field-list"*"| .id") echo FLD_x ;;
  "project field-list"*) i=0; for s in "👤 Inbox" "👤 Ready for Refinement" "🤖 Technical Refinement" "👤 Spec Review" "👤 Ready for Dev" "🤖 Coding" "🤖 Validation" "👤 Staged" "👤 Ready for Prod" "🤖 Done"; do i=$((i+1)); printf '%s\topt%s\n' "$s" "$i"; done ;;
  "project item-list"*group_by*) echo "Coding: 1" ;;
  "project item-list"*) printf 'I1\t🤖 Coding\n' ;;
  "api graphql"*|"project item-edit"*|"label create"*) ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$GS/gh"
H2="$SHIPFLOOR_HOME/projects/shop"

# AC-8 setup-board <slug>: runs setup-board.sh in the project's control checkout, with the project's config and home
echo "PVT_x FLD_x" > "$H2/board-ids"
out="$(PATH="$GS:$PATH" bash "$M" setup-board shop 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "AC-8 setup-board shop exits 0" || fail "AC-8 setup-board exit $rc: $out"
assert_contains "$(head -1 "$G/calls")" "$H2/control"$'\t'"project view 7 --owner acme"
assert_contains "$(cat "$G/calls")" "project item-edit --project-id PVT_x --id I1 --field-id FLD_x --single-select-option-id opt6"
assert_contains "$(cat "$G/calls")" "label create blocked --repo acme/shop"
[ ! -e "$H2/board-ids" ] && pass "AC-8 setup-board removed the project's board-ids" || fail "AC-8 board-ids left in $H2"
assert_contains "$out" "): 1 items"
assert_contains "$out" "Coding: 1"
assert_exit 1 bash "$M" setup-board nope
assert_contains "$(bash "$M" setup-board nope 2>&1)" "shipfloor: no project 'nope' (shipfloor list)"
assert_exit 1 bash "$M" setup-board

# AC-8 metrics <slug>: metrics.sh on the project's reports
mkdir -p "$H2/reports-wt/reports/9-x"
echo '{"issue":9,"slug":"x","pipeline":"refine","outcome":"ok","agents":[{"role":"po","tokens":500}],"rounds":{"a":1},"gates_failed":[],"manual_edit":false,"started_at":"2026-10-09T10:00:00-03:00","finished_at":"2026-10-09T10:05:00-03:00"}' > "$H2/reports-wt/reports/9-x/refine-1.json"
out="$(bash "$M" metrics shop 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "AC-8 metrics shop exits 0" || fail "AC-8 metrics exit $rc: $out"
[ "$out" = $'issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit\n9\trefine\tok\t500\t5\t1\t\tFalse' ] && pass "AC-8 metrics prints the header and one line per report" || fail "AC-8 metrics output: $out"
assert_exit 1 bash "$M" metrics nope

# AC-8 dashboard: the first line is "shipfloor dashboard: <url>  (Ctrl+C stops it)", the one skills/dashboard reads
dash() {  # dash <out file> <args...>: starts the dashboard, waits for its first line, stops it
  local f="$1" pid; shift
  CLAUDE_CONFIG_DIR="$(mktemp -d)" bash "$M" dashboard "$@" > "$f" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -s "$f" ] && break; sleep 0.1; done
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
dash "$G/dash1" --port 0 --no-open
first="$(head -1 "$G/dash1" | tr -d '\r')"
[[ "$first" =~ ^shipfloor\ dashboard:\ http://127\.0\.0\.1:[0-9]+/\?t=[^\ ]+\ \ \(Ctrl\+C\ stops\ it\)$ ]] && pass "AC-8 dashboard first line: shipfloor dashboard: <url>  (Ctrl+C stops it)" || fail "AC-8 dashboard first line: $first"
dash "$G/dash2" --port 0 --no-open --token sekret
assert_contains "$(head -1 "$G/dash2")" "/?t=sekret  (Ctrl+C stops it)"

# AC-8 pool stacks <n>: the machine's stack slots; the machine config is the only thing it writes
assert_exit 0 bash "$M" pool stacks 5
out="$(bash "$M" pool)"; assert_contains "$out" "stacks: 5"; assert_contains "$out" "slot 4: free"
assert_contains "$(cat "$SHIPFLOOR_HOME/config.yml")" "stacks: 5"
assert_exit 1 bash "$M" pool stacks x
assert_exit 1 bash "$M" pool stacks
assert_exit 1 bash "$M" pool stacks 0
assert_contains "$(bash "$M" pool)" "stacks: 5"   # a refused value leaves the setting alone
assert_exit 0 bash "$M" pool stacks 3
assert_contains "$(bash "$M" pool)" "stacks: 3"
assert_exit 2 bash "$M" pool bogus

# AC-8 add --main <b>: the project follows that branch, not origin/HEAD or main
tcfg="$(sed -e 's/name: shop/name: trunky/' -e 's#acme/shop#acme/trunky#' "$FACTORY_DIR/test/fixture/factory.yml")"
tr="$(with_config "$tcfg")"
git -C "$tr" push -q origin main:trunk
git -C "$tr" commit -q --allow-empty -m "main moves on"; git -C "$tr" push -q origin main
assert_exit 0 bash "$M" add "$tr" --main trunk
assert_contains "$(cat "$SHIPFLOOR_HOME/registry.tsv")" "trunky	$(git -C "$tr" rev-parse --show-toplevel)	$SHIPFLOOR_HOME/projects/trunky/wt	trunk"
[ "$(git -C "$SHIPFLOOR_HOME/projects/trunky/control" rev-parse HEAD)" = "$(git -C "$tr" rev-parse origin/trunk)" ] && pass "AC-8 add --main: the control checkout is at origin/trunk" || fail "AC-8 control checkout is not at origin/trunk"
[ "$(git -C "$SHIPFLOOR_HOME/projects/trunky/control" rev-parse HEAD)" != "$(git -C "$tr" rev-parse origin/main)" ] && pass "AC-8 add --main: not at origin/main" || fail "AC-8 control checkout followed main"
assert_exit 1 bash "$M" add "$tr" --main nope-branch
assert_exit 2 bash "$M" add "$tr" --bogus

# AC-8 doctor: the gh-auth line, the branch-protection line of each project and the models line
dr() { HOME="$dh" PATH="$GS:$SB:$PATH" SF_UNAME=Linux bash "$M" doctor 2>&1; }
echo true > "$G/protection"
out="$(dr)"
assert_contains "$out" "ok   gh authenticated"
assert_contains "$out" "ok   shop: main requires up-to-date branches"
assert_contains "$out" "ok   models"
touch "$G/noauth"; echo false > "$G/protection"
out="$(dr)"
assert_contains "$out" "FAIL gh auth login"
case "$out" in *"ok   gh authenticated"*) fail "AC-8 doctor says gh is authenticated while it is not" ;; *) pass "AC-8 doctor: no gh-auth ok line without auth" ;; esac
assert_contains "$out" "WARN shop: main does not require up-to-date branches (false); a hand merge can race the deploy"
assert_exit 1 env HOME="$dh" PATH="$GS:$SB:$PATH" SF_UNAME=Linux bash "$M" doctor   # a failed check makes doctor exit 1
rm -f "$G/noauth"
printf 'gh: Branch not protected (HTTP 404)\n' > "$G/protection"; touch "$G/protection-fails"
assert_contains "$(dr)" "WARN shop: main does not require up-to-date branches (Branch not protected (HTTP 404)); a hand merge can race the deploy"
cp "$SHIPFLOOR_HOME/config.yml" "$G/config.yml.bak"
printf 'models:\n  stages: {develop: gpt}\n' >> "$SHIPFLOOR_HOME/config.yml"
out="$(dr)"
assert_contains "$out" 'WARN models: models.stages.develop: "gpt" is not a model the factory knows (opus, sonnet, haiku, fable)'
case "$out" in *"ok   models"*) fail "AC-8 doctor says ok models beside a models warning" ;; *) pass "AC-8 doctor: a models warning replaces the ok line" ;; esac
cp "$G/config.yml.bak" "$SHIPFLOOR_HOME/config.yml"

# AC-8 the usage: a command the CLI does not know prints the header lines 2-10 of scripts/shipfloor (comment marks off) on stderr, exit 2.
# Today that stops one line short of the header: the dashboard line (line 11) is not in it.
want=$'shipfloor: installs the factory scripts and manages the projects the dispatcher serves.\n  install [--force]             copy scripts and templates to ~/.shipfloor/factory\n  doctor                        check tools, the installed copy and every project\'s config\n  add <repo> [--worktrees DIR]  register a local clone whose origin/main has .shipfloor/factory.yml\n  remove <slug> | list | pause [slug] | resume [slug] | setup-board <slug> | metrics <slug>\n  pool [set <n> | stage <stage> <n> | stacks <n>]  runs at once on this machine, per stage, and stack slots\n  clean <slug>                  remove what cards left under tmp/ (the dispatcher does it every cycle)\n  accept <slug> <n> <reason>    owner only: take card <n>\'s acceptance tests as they stand (acceptance-intact)\n  weight <slug> <n> <light|standard|heavy>  owner only: card <n>\'s weight, in Spec Review (the model its runs take)'
out="$(bash "$M" nonsense 2>&1 >/dev/null)"
[ "$out" = "$want" ] && pass "AC-8 the usage is the header's lines 2-10, '# ' removed" || fail "AC-8 usage text: $out"
assert_exit 2 bash "$M" nonsense
[ "$(bash "$M" 2>&1 >/dev/null)" = "$want" ] && pass "AC-8 no command prints the same usage" || fail "AC-8 no command: usage differs"
[ -z "$(bash "$M" nonsense 2>/dev/null)" ] && pass "AC-8 the usage goes to stderr only" || fail "AC-8 the usage reached stdout"
case "$out" in *"dashboard [--port"*) fail "AC-8 the usage now lists dashboard (line 11 of the header)" ;; *) pass "AC-8 the usage stops before the dashboard line, as today" ;; esac

# ---- #170 (PY-17): the CLI is shipfloor_core/cli.py behind a Bash wrapper; what it prints, writes and exits with stays
# AC-1 help prints the same usage as an unknown command, on stderr only, exit 2
assert_exit 2 bash "$M" help
[ "$(bash "$M" help 2>&1 >/dev/null)" = "$want" ] && pass "#170 AC-1 help prints the usage" || fail "#170 AC-1 help prints: $(bash "$M" help 2>&1)"
[ -z "$(bash "$M" help 2>/dev/null)" ] && pass "#170 AC-1 help writes nothing on stdout" || fail "#170 AC-1 help wrote on stdout"
# the wrapper: the header stays, the code sources lib/py.sh and runs `sf.py cli`, never lib/project.sh
code="$(grep -vE '^[[:space:]]*(#|$)' "$M")"
[ "$(printf '%s\n' "$code" | wc -l)" -le 5 ] && pass "#170 scripts/shipfloor is a few lines" || fail "#170 scripts/shipfloor has logic:
$code"
case "$code" in *'lib/py.sh'*) pass "#170 scripts/shipfloor sources lib/py.sh" ;; *) fail "#170 scripts/shipfloor does not source lib/py.sh" ;; esac
case "$code" in *'set -- cli "$@"'*) pass "#170 scripts/shipfloor runs the cli command" ;; *) fail "#170 scripts/shipfloor never runs \`sf.py cli\`" ;; esac
case "$code" in *'lib/project.sh'*) fail "#170 scripts/shipfloor still sources lib/project.sh" ;; *) pass "#170 scripts/shipfloor does not source lib/project.sh" ;; esac
[ "$(sed -n '2,10p' "$M" | sed 's/^# \{0,1\}//')" = "$want" ] && pass "#170 the wrapper keeps the header the usage comes from" || fail "#170 the wrapper's header lines 2-10 changed"
# sf.py knows the cli command
out="$("$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" cli nonsense 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ "$out" = "$want" ] && pass "#170 sf.py cli prints the usage for an unknown command, exit 2" || fail "#170 sf.py cli nonsense: exit $rc: $out"

# AC-7 the exact lines of add, list, remove and clean, the registry and the accepted.tsv records
trtop="$(git -C "$tr" rev-parse --show-toplevel)"
out="$(bash "$M" remove trunky 2>&1)"
[ "$out" = "removed trunky (logs and reports stay in $SHIPFLOOR_HOME/projects/trunky)" ] && pass "#170 AC-7 remove prints one line" || fail "#170 AC-7 remove printed: $out"
out="$(bash "$M" add "$tr" --main trunk 2>&1)"
[ "$out" = "registered trunky ($trtop, worktrees in $SHIPFLOOR_HOME/projects/trunky/wt)" ] && pass "#170 AC-7 add prints one line" || fail "#170 AC-7 add printed: $out"
[ "$(grep '^trunky	' "$SHIPFLOOR_HOME/registry.tsv")" = "trunky	$trtop	$SHIPFLOOR_HOME/projects/trunky/wt	trunk" ] && [ "$(wc -l < "$SHIPFLOOR_HOME/registry.tsv" | tr -d ' ')" = 2 ] \
  && pass "#170 AC-7 registry.tsv: one line per project, slug repo worktrees main" || fail "#170 AC-7 registry.tsv: $(cat "$SHIPFLOOR_HOME/registry.tsv")"
want_list="$(awk -F'\t' 'NF{print $1"\tactive\t"$2"\t"$3}' "$SHIPFLOOR_HOME/registry.tsv")"
[ "$(bash "$M" list 2>&1)" = "$want_list" ] && pass "#170 AC-7 list: slug, state, repo, worktrees" || fail "#170 AC-7 list printed: $(bash "$M" list 2>&1)"
bash "$M" pause trunky; bash "$M" pause
[ "$(bash "$M" list 2>&1)" = "(all paused)
${want_list/trunky	active/trunky	paused}" ] && pass "#170 AC-7 list with everything paused" || fail "#170 AC-7 list printed: $(bash "$M" list 2>&1)"
bash "$M" resume; bash "$M" resume trunky
mkdir -p "$H2/tmp/5/x"
out="$(bash "$M" clean shop 2>&1)"; rc=$?
[ "$rc:$out" = "0:removed tmp/5" ] && pass "#170 AC-7 clean prints each folder it removed" || fail "#170 AC-7 clean: exit $rc: $out"
grep -qE "^api/src/test/NineTest\.kt	[^	]+	#9	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}	main reworded the setup$" "$H2/accepted.tsv" \
  && pass "#170 AC-7 accepted.tsv: file, key, #n, date -Is, reason" || fail "#170 AC-7 accepted.tsv: $(cat "$H2/accepted.tsv")"
grep -qE "^api/src/test/RedStubs\.kt	deleted	#9	[^	]+	stub replaced$" "$H2/accepted.tsv" \
  && pass "#170 AC-7 accepted.tsv records a deletion with the key deleted" || fail "#170 AC-7 accepted.tsv: $(cat "$H2/accepted.tsv")"

# AC-6 doctor exits 0 when it only warns
printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/claude"; chmod +x "$GS/claude"; echo false > "$G/protection"; rm -f "$G/protection-fails"
out="$(dr)"; rc="$(HOME="$dh" PATH="$GS:$SB:$PATH" SF_UNAME=Linux bash "$M" doctor >/dev/null 2>&1; echo $?)"
case "$out" in *FAIL*) fail "#170 AC-6 doctor has a FAIL line in this setup: $out" ;; *) pass "#170 AC-6 no FAIL line" ;; esac
assert_contains "$out" "WARN shop: main does not require up-to-date branches"
[ "$rc" = 0 ] && pass "#170 AC-6 doctor exits 0 with warnings only" || fail "#170 AC-6 doctor exits $rc with warnings only"
finish
