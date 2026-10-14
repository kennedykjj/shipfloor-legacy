#!/usr/bin/env bash
# #171 (PY-18): lib/project.sh answers as before and its shipfloor_resolve exports the project into the caller's shell
# (AC-6); shipfloor-config.sh keeps its step fast path, which starts no Python (AC-7); docs/contracts.md names the Python
# module behind each script (AC-10); and every deploy.sh, gate.sh and board.sh command the skills, agents and docs run
# is one the script knows (AC-12). That the scripts are wrappers and shims is hygiene.test.sh's.
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

# ---------------------------------------------------------------- AC-6: lib/project.sh
lib="$FACTORY_DIR/lib/project.sh"
printf '**Weight:** light\n\n## Product\n' > "$T/spec.md"
# the answers
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
lock="$(mktemp -d)"
rec env SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step 3; rc=$?
[ "$rc" = 0 ] && [ ! -s "$RECPY_LOG" ] && pass "AC-7 step 3: exit 0, no Python started" || fail "AC-7 step 3: exit $rc, python: $(cat "$RECPY_LOG")"
case "$(cat "$lock/step" 2>/dev/null)" in 3$'\t'[0-9]*) pass "AC-7 step 3 writes '3<TAB><epoch>'" ;; *) fail "AC-7 step file: '$(cat "$lock/step" 2>/dev/null)'" ;; esac
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

# ---------------------------------------------------------------- AC-10: docs/contracts.md names the module behind each script
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
PY
)"
[ -z "$miss" ] && pass "AC-10 docs/contracts.md names the Python module behind each script" || fail "AC-10 docs/contracts.md sections with no Python module named: $(echo $miss)"

# ---------------------------------------------------------------- AC-12: the callers run commands the scripts know
callers() {  # the deploy.sh, gate.sh and board.sh commands in skills/, agents/ and docs/*.md, one per line, sorted
  (cd "$ROOT" && grep -rohE '(bash [^ `]*/)?(deploy|gate|board)\.sh( [a-z][a-z-]*)?' skills agents docs/*.md | sed -E 's#^bash [^ ]*/##' | sort -u)
}
usage="$(bash "$FACTORY_DIR/gate.sh" --help)"; boardpy="$(cat "$FACTORY_DIR/shipfloor_core/board.py")"
unknown=""; n=0
while read -r script sub; do
  n=$((n+1)); [ -n "$sub" ] || continue
  case "$script" in
    gate.sh) case "$usage" in *$'\n'"  $sub "*) ;; *) unknown="$unknown gate.sh:$sub" ;; esac ;;
    board.sh) case "$boardpy" in *"cmd == \"$sub\""*) ;; *) unknown="$unknown board.sh:$sub" ;; esac ;;
    deploy.sh) unknown="$unknown deploy.sh:$sub" ;;  # deploy.sh takes a card number, no subcommand
  esac
done < <(callers)
[ "$n" -ge 5 ] && pass "AC-12 the skills, agents and docs name $n deploy.sh, gate.sh and board.sh commands" || fail "AC-12 only $n caller commands found"
[ -z "$unknown" ] && pass "AC-12 every one of them is a command the script knows" || fail "AC-12 commands the scripts do not know:$unknown"
finish
