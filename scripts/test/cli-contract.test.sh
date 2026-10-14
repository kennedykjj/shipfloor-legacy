#!/usr/bin/env bash
# suite: integration
# The shipfloor CLI and project shims through real processes (the behavior is py/cli_*.py's, in process): the wrapper
# scripts/shipfloor and sf.py cli (usage on stderr, exit 2; a first install from a plain copy), the dashboard's first
# line, lib/project.sh (shipfloor_resolve's eval of a path that holds quotes and $( ), no Python when FACTORY_CONFIG is
# set), shipfloor-config.sh (the step fast path starts no Python; exit 1 / 2), the hook command, and every deploy.sh,
# gate.sh and board.sh command the skills, agents and docs run being one the script knows.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
ROOT="$(cd "$FACTORY_DIR/.." && pwd)"
M="$FACTORY_DIR/shipfloor"; CFG="$FACTORY_DIR/shipfloor-config.sh"; lib="$FACTORY_DIR/lib/project.sh"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT FACTORY_MAIN SHIPFLOOR_PY
export SHIPFLOOR_HOME="$T/sh"

# ---- the wrapper: the usage is the header's lines 2-10, '# ' removed, on stderr only, exit 2 (sf.py cli the same)
want=$'shipfloor: installs the factory scripts and manages the projects the dispatcher serves.\n  install [--force]             copy scripts and templates to ~/.shipfloor/factory\n  doctor                        check tools, the installed copy and every project\'s config\n  add <repo> [--worktrees DIR]  register a local clone whose origin/main has .shipfloor/factory.yml\n  remove <slug> | list | pause [slug] | resume [slug] | setup-board <slug> | metrics <slug>\n  pool [set <n> | stage <stage> <n> | stacks <n>]  runs at once on this machine, per stage, and stack slots\n  clean <slug>                  remove what cards left under tmp/ (the dispatcher does it every cycle)\n  accept <slug> <n> <reason>    owner only: take card <n>\'s acceptance tests as they stand (acceptance-intact)\n  weight <slug> <n> <light|standard|heavy>  owner only: card <n>\'s weight, in Spec Review (the model its runs take)'
[ "$(sed -n '2,10p' "$M" | sed 's/^# \{0,1\}//')" = "$want" ] && pass "the wrapper's header lines 2-10 are the usage" || fail "the wrapper's header lines 2-10 changed"
out="$(bash "$M" nonsense 2>&1 >/dev/null)"; rc=$?
[ "$rc:$out" = "2:$want" ] && pass "shipfloor nonsense: the usage on stderr, exit 2" || fail "shipfloor nonsense: exit $rc: $out"
[ -z "$(bash "$M" help 2>/dev/null)" ] && pass "help writes nothing on stdout" || fail "help wrote on stdout"
out="$("$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" cli nonsense 2>&1)"; rc=$?
[ "$rc:$out" = "2:$want" ] && pass "sf.py cli prints the usage for an unknown command, exit 2" || fail "sf.py cli nonsense: exit $rc: $out"
pc="$(plugin_copy)"
out="$(bash "$pc/scripts/shipfloor" install 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$SHIPFLOOR_HOME/factory/gate.sh" ] && pass "a first install runs from a plain copy, before any ~/.shipfloor" || fail "install from a copy: exit $rc: $out"
assert_contains "$out" "installed $pc → $SHIPFLOOR_HOME/factory: "

# ---- the dashboard: the first line is "shipfloor dashboard: <url>  (Ctrl+C stops it)", the one skills/dashboard reads
dash() {  # dash <out file> <args...>: starts the dashboard, waits for its first line, stops it
  local f="$1" pid; shift
  CLAUDE_CONFIG_DIR="$T/claude" bash "$M" dashboard "$@" > "$f" 2>&1 &
  pid=$!
  wait_for "the dashboard's first line" test -s "$f"
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
dash "$T/dash1" --port 0 --no-open
first="$(head -1 "$T/dash1" | tr -d '\r')"
[[ "$first" =~ ^shipfloor\ dashboard:\ http://127\.0\.0\.1:[0-9]+/\?t=[^\ ]+\ \ \(Ctrl\+C\ stops\ it\)$ ]] && pass "dashboard first line: shipfloor dashboard: <url>  (Ctrl+C stops it)" || fail "dashboard first line: $first"
dash "$T/dash2" --port 0 --no-open --token sekret
assert_contains "$(head -1 "$T/dash2")" "/?t=sekret  (Ctrl+C stops it)"

# ---- lib/project.sh: the shim's answers, and shipfloor_resolve's eval
cat > "$T/recpy" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RECPY_LOG"
exec "$REAL_PYTHON" "$@"
EOS
chmod +x "$T/recpy"
export REAL_PYTHON="$FACTORY_PYTHON" RECPY_LOG="$T/py.log"
rec() { : > "$RECPY_LOG"; FACTORY_PYTHON="$T/recpy" "$@"; }   # rec <command...>: run it with a python that logs its calls
printf '**Weight:** light\n\n## Product\n' > "$T/spec.md"
FX="$FACTORY_DIR/test/fixture/factory.yml"
[ "$(bash -c "source '$lib'; shipfloor_spec_weight '$T/spec.md'")" = light ] && pass "shipfloor_spec_weight answers" || fail "shipfloor_spec_weight"
[ "$(FACTORY_CONFIG="$FX" bash -c "source '$lib'; shipfloor_cfg get project.repo")" = acme/shop ] && pass "shipfloor_cfg answers for the project" || fail "shipfloor_cfg get project.repo"
bash -c "source '$lib'; ere_ok 'a('" 2>/dev/null && fail "ere_ok accepted an invalid pattern" || pass "ere_ok refuses an invalid pattern (its exit code reaches the caller)"
[ "$(bash -c "source '$lib'; printf 'deploy #7: merged\n' | shipfloor_say en")" = "deploy #7: merged" ] && pass "shipfloor_say reads stdin" || fail "shipfloor_say en"
H="$T/home"; mkdir -p "$H"
odd="$T/my 'odd' \$HOME \`touch pwned\` \$(touch pwned) repo"
mkdir -p "$odd"; cp -r "$REPO_TEMPLATE/." "$odd/"
printf 'shop\t%s\t%s\ttrunk\n' "$odd" "$T/wt dir" > "$H/registry.tsv"
cd "$odd" || exit 1
got="$(SHIPFLOOR_HOME="$H" bash -c "source '$lib'; shipfloor_resolve && bash -c 'printf \"%s|\" \"\$FACTORY_PROJECT\" \"\$FACTORY_REPO\" \"\$FACTORY_MAIN\" \"\$FACTORY_HOME\" \"\$FACTORY_WT_ROOT\" \"\$FACTORY_CONFIG\"'" 2>&1)"
[ "$got" = "shop|$odd|trunk|$H/projects/shop|$T/wt dir|$H/projects/shop/factory.yml|" ] && pass "shipfloor_resolve exports the six FACTORY_* variables into the caller's shell, values intact" || fail "shipfloor_resolve exported: $got"
[ ! -e "$odd/pwned" ] && [ ! -e "$T/pwned" ] && pass "nothing in the path was run by the eval" || fail "the eval ran part of the path (pwned exists)"
got="$(bash -c "source '$lib'; shipfloor_use web '/r e/p' '' dev && printf '%s|%s|%s' \"\$FACTORY_PROJECT\" \"\$FACTORY_REPO\" \"\$FACTORY_MAIN\"")"
[ "$got" = "web|/r e/p|dev" ] && pass "shipfloor_use exports the given project" || fail "shipfloor_use: '$got'"
mkdir -p "$T/elsewhere"; cd "$T/elsewhere" || exit 1
out="$(SHIPFLOOR_HOME="$H" bash -c "source '$lib'; shipfloor_resolve; echo \"rc=\$?\"" 2>&1)"
assert_contains "$out" "shipfloor: $T/elsewhere is not in a registered project (shipfloor add <repo>)"
assert_contains "$out" "rc=1"
rec env FACTORY_CONFIG="$FX" bash -c "source '$lib'; shipfloor_resolve"
[ ! -s "$RECPY_LOG" ] && pass "shipfloor_resolve with FACTORY_CONFIG set starts no Python" || fail "shipfloor_resolve started Python: $(cat "$RECPY_LOG")"

# ---- shipfloor-config.sh: the step fast path, and the exit codes through the wrapper
lock="$T/lock"; mkdir -p "$lock"
rec env FACTORY_CONFIG="$FX" SHIPFLOOR_RUN_LOCK="$lock" bash "$CFG" step 3; rc=$?
[ "$rc" = 0 ] && [ ! -s "$RECPY_LOG" ] && pass "step 3: exit 0, no Python started" || fail "step 3: exit $rc, python: $(cat "$RECPY_LOG")"
case "$(cat "$lock/step" 2>/dev/null)" in 3$'\t'[0-9]*) pass "step 3 writes '3<TAB><epoch>'" ;; *) fail "step file: '$(cat "$lock/step" 2>/dev/null)'" ;; esac
[ "$(FACTORY_CONFIG="$FX" bash "$CFG" get project.repo)" = acme/shop ] && pass "get project.repo answers" || fail "get project.repo"
cp "$FX" "$T/bad.yml"; printf 'acceptance_assertions: "[[:foo:]]"\n' >> "$T/bad.yml"  # Python's re takes it, grep -E does not
out="$(FACTORY_CONFIG="$T/bad.yml" bash "$CFG" validate 2>&1)"; rc=$?
[ "$rc" = 1 ] && pass "validate: an invalid grep -E pattern is exit 1" || fail "validate: exit $rc: $out"
assert_contains "$out" "is not a valid grep -E pattern"
out="$(SHIPFLOOR_HOME="$H" bash "$CFG" get project.repo 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "no project: exit 2" || fail "no project: exit $rc"
assert_contains "$out" "is not in a registered project"
cd "$T" || exit 1

# ---- the hook command is unchanged
assert_contains "$(cat "$ROOT/hooks/hooks.json")" '"command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/inbox-hook.sh\""'

# ---- the callers run commands the scripts know: every deploy.sh, gate.sh and board.sh command in skills/, agents/, docs/*.md
callers() { (cd "$ROOT" && grep -rohE '(bash [^ `]*/)?(deploy|gate|board)\.sh( [a-z][a-z-]*)?' skills agents docs/*.md | sed -E 's#^bash [^ ]*/##' | sort -u); }
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
[ "$n" -ge 5 ] && pass "the skills, agents and docs name $n deploy.sh, gate.sh and board.sh commands" || fail "only $n caller commands found"
[ -z "$unknown" ] && pass "every one of them is a command the script knows" || fail "commands the scripts do not know:$unknown"
finish
