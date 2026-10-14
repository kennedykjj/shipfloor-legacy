#!/usr/bin/env bash
# #171 (PY-18): the migration is finished. lib/project.sh is a shim over `sf.py project` whose shipfloor_resolve exports
# the project into the caller's shell (AC-6); shipfloor-config.sh keeps its step fast path and sends the rest to
# `sf.py config` (AC-7); the docs describe the Python package (AC-10); no bash 4.4 requirement is left (AC-11); and the
# callers run the same deploy.sh, gate.sh and board.sh commands as before the migration (AC-12).
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
ROOT="$(cd "$FACTORY_DIR/.." && pwd)"
CFG="$FACTORY_DIR/shipfloor-config.sh"
unset SHIPFLOOR_PY

# a python that logs its arguments (one call per line) and then runs the real one
cat > "$T/recpy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RECPY_LOG"
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$T/recpy"
export REAL_PYTHON="$FACTORY_PYTHON" RECPY_LOG="$T/py.log"
rec() { : > "$RECPY_LOG"; FACTORY_PYTHON="$T/recpy" "$@"; }   # rec <command...>: run it with the logging python
started() { grep -q -- "$1" "$RECPY_LOG"; }

# ---------------------------------------------------------------- AC-6: lib/project.sh is a shim over sf.py project
lib="$FACTORY_DIR/lib/project.sh"
code="$(grep -vE '^[[:space:]]*(#|$)' "$lib")"
case "$code" in *"sf.py"*) pass "AC-6 lib/project.sh runs sf.py" ;; *) fail "AC-6 lib/project.sh never names sf.py" ;; esac
if printf '%s\n' "$code" | grep -qE '(^|[^_a-z])(awk|sed|grep|find|git) '; then fail "AC-6 lib/project.sh still runs awk, sed, grep, find or git:
$(printf '%s\n' "$code" | grep -nE '(^|[^_a-z])(awk|sed|grep|find|git) ')"; else pass "AC-6 lib/project.sh runs no awk, sed, grep, find or git"; fi

# each function goes through `sf.py project <command>`
printf '**Weight:** light\n\n## Product\n' > "$T/spec.md"
via() {  # via <label> <sf.py project command> <shell code after sourcing lib/project.sh>
  rec bash -c "source '$lib'; $3" >/dev/null 2>&1 </dev/null
  if grep -qE -- "sf\.py project $2( |\$)" "$RECPY_LOG"; then pass "AC-6 $1 runs sf.py project $2"; else fail "AC-6 $1 does not run 'sf.py project $2' (python ran: $(tr '\n' ';' < "$RECPY_LOG"))"; fi
}
via shipfloor_cfg cfg "shipfloor_cfg get project.repo"
via shipfloor_machine machine "shipfloor_machine values pool"
via shipfloor_spec_weight spec-weight "shipfloor_spec_weight '$T/spec.md'"
via shipfloor_card_weight card-weight "shipfloor_card_weight 7"
via shipfloor_say say "echo hi | shipfloor_say pt-BR"
via shipfloor_sweep_tmp sweep-tmp "shipfloor_sweep_tmp"
via ere_ok ere-ok "ere_ok 'a+'"
via shipfloor_validate validate "shipfloor_validate"
via shipfloor_use use "shipfloor_use shop /x"

# the answers are the same as before
w="$(bash -c "source '$lib'; shipfloor_spec_weight '$T/spec.md'")"
[ "$w" = light ] && pass "AC-6 shipfloor_spec_weight reads the weight line" || fail "AC-6 shipfloor_spec_weight said '$w'"
[ "$(bash -c "source '$lib'; shipfloor_cfg get project.repo")" = acme/shop ] && pass "AC-6 shipfloor_cfg answers for the project" || fail "AC-6 shipfloor_cfg get project.repo: $(bash -c "source '$lib'; shipfloor_cfg get project.repo" 2>&1)"
bash -c "source '$lib'; ere_ok 'a('" 2>/dev/null && fail "AC-6 ere_ok accepted an invalid pattern" || pass "AC-6 ere_ok refuses an invalid pattern"
bash -c "source '$lib'; ere_ok '^[0-9]+\$'" && pass "AC-6 ere_ok accepts a valid pattern" || fail "AC-6 ere_ok refused a valid pattern"
said="$(bash -c "source '$lib'; printf 'deploy #7: merged\n' | shipfloor_say en")"
[ "$said" = "deploy #7: merged" ] && pass "AC-6 shipfloor_say en passes the text unchanged" || fail "AC-6 shipfloor_say en: '$said'"

# shipfloor_resolve exports the registered project into the caller's shell; a path with a space, a quote, a $ and a
# backtick stays intact, and nothing in it is run
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT FACTORY_MAIN
H="$T/home"; mkdir -p "$H"
odd="$T/my 'odd' \$HOME \`touch pwned\` \$(touch pwned) repo"
mkdir -p "$odd"; cp -r "$REPO_TEMPLATE/." "$odd/"
printf 'shop\t%s\t%s\ttrunk\n' "$odd" "$T/wt dir" > "$H/registry.tsv"
cd "$odd" || exit 1
got="$(SHIPFLOOR_HOME="$H" bash -c "source '$lib'; shipfloor_resolve && bash -c 'printf \"%s|\" \"\$FACTORY_PROJECT\" \"\$FACTORY_REPO\" \"\$FACTORY_MAIN\" \"\$FACTORY_HOME\" \"\$FACTORY_WT_ROOT\" \"\$FACTORY_CONFIG\"'" 2>&1)"
want="shop|$odd|trunk|$H/projects/shop|$T/wt dir|$H/projects/shop/factory.yml|"
[ "$got" = "$want" ] && pass "AC-6 shipfloor_resolve exports the six FACTORY_* variables, values intact" || fail "AC-6 shipfloor_resolve exported
  got:  $got
  want: $want"
[ ! -e "$odd/pwned" ] && [ ! -e "$T/pwned" ] && pass "AC-6 nothing in the path was run by the eval" || fail "AC-6 the eval ran part of the path (pwned exists)"
printf 'shop\t%s\n' "$odd" > "$H/registry.tsv"
got="$(SHIPFLOOR_HOME="$H" bash -c "source '$lib'; shipfloor_resolve && printf '%s|%s' \"\$FACTORY_MAIN\" \"\$FACTORY_WT_ROOT\"")"
[ "$got" = "main|$H/projects/shop/wt" ] && pass "AC-6 the defaults: main and <home>/wt" || fail "AC-6 defaults: '$got'"
got="$(bash -c "source '$lib'; shipfloor_use web '/r e/p' '' dev && printf '%s|%s|%s|%s' \"\$FACTORY_PROJECT\" \"\$FACTORY_REPO\" \"\$FACTORY_WT_ROOT\" \"\$FACTORY_MAIN\"")"
case "$got" in "web|/r e/p|"*"/projects/web/wt|dev") pass "AC-6 shipfloor_use exports the given project" ;; *) fail "AC-6 shipfloor_use: '$got'" ;; esac
cd "$T" || exit 1
mkdir -p "$T/elsewhere"; cd "$T/elsewhere" || exit 1
out="$(SHIPFLOOR_HOME="$H" bash -c "source '$lib'; shipfloor_resolve; echo \"rc=\$?\"" 2>&1)"
assert_contains "$out" "shipfloor: $T/elsewhere is not in a registered project (shipfloor add <repo>)"
assert_contains "$out" "rc=1"
cd "$T" || exit 1
# with FACTORY_CONFIG set the project is known: no Python is started
rec env FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml" bash -c "source '$lib'; shipfloor_resolve"
[ ! -s "$RECPY_LOG" ] && pass "AC-6 shipfloor_resolve with FACTORY_CONFIG set starts no Python" || fail "AC-6 shipfloor_resolve started Python with FACTORY_CONFIG set: $(cat "$RECPY_LOG")"

# ---------------------------------------------------------------- AC-7: shipfloor-config.sh
export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
code="$(grep -vE '^[[:space:]]*(#|$)' "$CFG")"
case "$code" in *"lib/project.sh"*) fail "AC-7 shipfloor-config.sh still sources lib/project.sh" ;; *) pass "AC-7 shipfloor-config.sh no longer sources lib/project.sh" ;; esac
lock="$(mktemp -d)"
rec env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step 3; rc=$?
[ "$rc" = 0 ] && [ ! -s "$RECPY_LOG" ] && pass "AC-7 step 3: exit 0, no Python started" || fail "AC-7 step 3: exit $rc, python: $(cat "$RECPY_LOG")"
case "$(cat "$lock/step" 2>/dev/null)" in 3$'\t'[0-9]*) pass "AC-7 step 3 writes '3<TAB><epoch>'" ;; *) fail "AC-7 step file: '$(cat "$lock/step" 2>/dev/null)'" ;; esac
for q in "machine values pool" "validate" "get project.repo"; do
  # shellcheck disable=SC2086
  rec bash "$CFG" $q >/dev/null 2>&1
  started "sf.py config $q" && pass "AC-7 '$q' runs sf.py config" || fail "AC-7 '$q' does not run 'sf.py config $q' (python ran: $(tr '\n' ';' < "$RECPY_LOG"))"
done
[ "$(bash "$CFG" get project.repo)" = acme/shop ] && pass "AC-7 get project.repo answers" || fail "AC-7 get project.repo: $(bash "$CFG" get project.repo 2>&1)"
[ "$(SHIPFLOOR_HOME="$H" bash "$CFG" machine values pool | tr '\0' ' ')" = "4 " ] && pass "AC-7 machine values pool answers without a project" || fail "AC-7 machine values pool: $(SHIPFLOOR_HOME="$H" bash "$CFG" machine values pool 2>&1 | tr '\0' ' ')"
assert_exit 0 bash "$CFG" validate
bad="$T/bad.yml"; cp "$FACTORY_DIR/test/fixture/factory.yml" "$bad"
printf 'acceptance_assertions: "[[:foo:]]"\n' >> "$bad"  # Python's re takes it, grep -E does not
out="$(FACTORY_CONFIG="$bad" bash "$CFG" validate 2>&1)"; rc=$?
[ "$rc" = 1 ] && pass "AC-7 validate: an invalid grep -E pattern is exit 1" || fail "AC-7 validate of an invalid pattern: exit $rc: $out"
assert_contains "$out" "is not a valid grep -E pattern"
cd "$T/elsewhere" || exit 1
out="$(env -u FACTORY_CONFIG SHIPFLOOR_HOME="$H" bash "$CFG" get project.repo 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "AC-7 no project: exit 2" || fail "AC-7 no project: exit $rc"
assert_contains "$out" "is not in a registered project"
cd "$T" || exit 1

# ---------------------------------------------------------------- AC-8: the hook command is unchanged
assert_contains "$(cat "$ROOT/hooks/hooks.json")" '"command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/inbox-hook.sh\""'

# ---------------------------------------------------------------- AC-10: the docs describe the Python package
stack="$(awk '/^## Stack/{f=1; next} /^## /{f=0} f' "$ROOT/PRODUCT.md")"
case "$stack" in *shipfloor_core*) pass "AC-10 PRODUCT.md Stack names the shipfloor_core package" ;; *) fail "AC-10 PRODUCT.md Stack does not name shipfloor_core: $stack" ;; esac
case "$stack" in *wrapper*) pass "AC-10 PRODUCT.md Stack says the Bash scripts are wrappers" ;; *) fail "AC-10 PRODUCT.md Stack does not say the scripts are wrappers" ;; esac
for f in README.md docs/install.md; do
  req="$(grep -iE 'Python 3\.11\+' "$ROOT/$f" | head -n1)"
  for w in "PyYAML" "Git" "gh" "Claude Code" "Git Bash on Windows"; do
    case "$req" in *"$w"*) pass "AC-10 $f requirements name $w" ;; *) fail "AC-10 $f requirements line does not name '$w': $req" ;; esac
  done
done
for f in docs/how-it-works.md docs/operation.md; do
  grep -q 'shipfloor_core' "$ROOT/$f" && pass "AC-10 $f says where the logic lives (shipfloor_core)" || fail "AC-10 $f does not name shipfloor_core"
done
miss="$("$FACTORY_PYTHON" -I - "$ROOT" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
doc = open(os.path.join(root, "docs", "contracts.md"), encoding="utf-8").read()
parts = re.split(r"^## +(.*)$", doc, flags=re.M)
secs = {parts[i].replace("`", "").strip().split(" ")[0]: parts[i + 1] for i in range(1, len(parts), 2)}
names = sorted(os.path.relpath(p, os.path.join(root, "scripts")).replace(os.sep, "/")
               for p in glob.glob(os.path.join(root, "scripts", "*.sh")) + glob.glob(os.path.join(root, "scripts", "lib", "*.sh")))
for n in names + ["shipfloor"]:
    body = secs.get(n, "")
    if not re.search(r"`(shipfloor_core/[a-z_/]+(\.py)?|sf\.py|inbox_hook\.py)`", body):
        print(n)
if "lib/portable.sh" in secs:
    print("lib/portable.sh (section left)")
PY
)"
[ -z "$miss" ] && pass "AC-10 docs/contracts.md names the Python module behind each script" || fail "AC-10 docs/contracts.md sections with no Python module named: $(echo $miss)"

# ---------------------------------------------------------------- AC-11: no bash 4.4 requirement is left
INST="$ROOT/installer/install-dispatcher.sh"
grep -qE 'BASH_VERSINFO|4\.4' "$INST" && fail "AC-11 install-dispatcher.sh still checks for bash 4.4: $(grep -nE 'BASH_VERSINFO|4\.4' "$INST")" || pass "AC-11 install-dispatcher.sh no longer checks the bash version"
grep -qiE '^#.*(wrapper|no bash).*' "$INST" && grep -qiE '^#.*bash.*(version|4\.4|any bash)|^#.*(version|any bash).*bash' "$INST" \
  && pass "AC-11 install-dispatcher.sh says why no bash version is needed" || fail "AC-11 install-dispatcher.sh does not say why it needs no bash version"
left="$(grep -rniE 'bash 4\.4|4\.4 or newer|bash >= ?4' "$ROOT/README.md" "$ROOT/PRODUCT.md" "$ROOT"/docs/*.md "$INST" 2>/dev/null)"
[ -z "$left" ] && pass "AC-11 no doc asks for bash 4.4" || fail "AC-11 still asks for bash 4.4: $left"
# an old bash (it fails the version test) on PATH still gets the dispatcher registered (Linux, systemd, all stand-ins)
S="$T/stubs"; mkdir -p "$S" "$T/st"
realbash="$(command -v bash)"
printf '#!%s\ncase "$*" in *BASH_VERSINFO*) exit 1 ;; esac\nexec %s "$@"\n' "$realbash" "$realbash" > "$S/bash"
printf '#!%s\ncase "$*" in *show-environment*) echo PATH=/usr/bin ;; esac\nexit 0\n' "$realbash" > "$S/systemctl"
printf '#!%s\necho Linger=no; exit 0\n' "$realbash" > "$S/loginctl"
printf '#!%s\nif [ "$1" = -s ]; then echo Linux; else exec %s "$@"; fi\n' "$realbash" "$(command -v uname)" > "$S/uname"
chmod +x "$S"/*
IH="$T/ihome"; mkdir -p "$IH/home" "$IH/sf/factory" "$IH/sf/logs"; cp -r "$FACTORY_DIR/." "$IH/sf/factory/"; rm -rf "$IH/sf/factory/test"
out="$(HOME="$IH/home" SHIPFLOOR_HOME="$IH/sf" PATH="$S:$PATH" bash "$INST" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "AC-11 a bash older than 4.4 on PATH: the dispatcher is registered" || fail "AC-11 with an old bash the installer exited $rc: $out"

# ---------------------------------------------------------------- AC-12: the callers did not change
callers() {  # the deploy.sh, gate.sh and board.sh commands in skills/, agents/ and docs/*.md, one per line, sorted
  (cd "$ROOT" && grep -rohE '(bash [^ `]*/)?(deploy|gate|board)\.sh( [a-z][a-z-]*)?' skills agents docs/*.md | sed -E 's#^bash [^ ]*/##' | sort -u)
}
before="$FACTORY_DIR/test/fixtures/callers-before-migration.txt"
if [ -f "$before" ]; then
  d="$(diff "$before" <(callers))"
  [ -z "$d" ] && pass "AC-12 skills, agents and docs run the same deploy.sh, gate.sh and board.sh commands as before the migration" || fail "AC-12 the callers' commands changed:
$d"
else
  fail "AC-12 no test/fixtures/callers-before-migration.txt"
fi
finish
