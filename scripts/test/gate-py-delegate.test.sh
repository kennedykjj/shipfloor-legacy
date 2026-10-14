#!/usr/bin/env bash
# AC-9 of #165: gate.sh is a wrapper. The static gates (scope, forbidden, acceptance-intact, acceptance-own, qa-commit,
# qa-amend, migration, fast, test-plan, weight) are Python (shipfloor_core.gate.main, through sf.py gate);
# build|red|green|stack are handed to scripts/lib/gate-run.sh with the arguments unchanged (-C included).
# The existing gate-*, stack-lock, dispatch-stepup, deploy-* and py-* suites are not edited by the card.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"

# ---- the pieces exist
[ -f "$FACTORY_DIR/lib/gate-run.sh" ] && pass "AC-9 scripts/lib/gate-run.sh exists" || fail "AC-9 scripts/lib/gate-run.sh does not exist"
[ -d "$FACTORY_DIR/shipfloor_core/gate" ] && [ -f "$FACTORY_DIR/shipfloor_core/gate/__init__.py" ] && [ -f "$FACTORY_DIR/shipfloor_core/gate/main.py" ] && pass "AC-9 shipfloor_core/gate/ has __init__.py and main.py" || fail "AC-9 scripts/shipfloor_core/gate/{__init__,main}.py do not exist"
for m in changes scope acceptance migration spec; do
  [ -f "$FACTORY_DIR/shipfloor_core/gate/$m.py" ] && pass "AC-9 shipfloor_core/gate/$m.py exists" || fail "AC-9 scripts/shipfloor_core/gate/$m.py does not exist"
done
"$FACTORY_PYTHON" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import shipfloor_core.gate as g; sys.exit(0 if callable(getattr(g, "main", None)) else 1)' "$FACTORY_DIR" 2>"$T/imp" \
  && pass "AC-9 shipfloor_core.gate.main is importable and callable" || fail "AC-9 shipfloor_core.gate.main is not importable: $(tail -1 "$T/imp")"
"$FACTORY_PYTHON" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import shipfloor_core.gate as g; sys.exit(0 if g.main(["--help"]) == 0 else 1)' "$FACTORY_DIR" >/dev/null 2>&1 \
  && pass "AC-9 shipfloor_core.gate.main(['--help']) returns 0" || fail "AC-9 shipfloor_core.gate.main(['--help']) does not return 0"
if [ -f "$FACTORY_DIR/lib/gate-run.sh" ]; then
  body="$(cat "$FACTORY_DIR/lib/gate-run.sh")"
  for g in gate_build gate_red gate_green gate_stack; do
    case "$body" in *"$g"*) pass "AC-9 gate-run.sh holds $g" ;; *) fail "AC-9 gate-run.sh has no $g" ;; esac
  done
  for g in gate_scope gate_forbidden gate_migration gate_acceptance_intact gate_test_plan gate_weight gate_qa_amend gate_qa_commit gate_fast; do
    case "$body" in *"$g"*) fail "AC-9 gate-run.sh still holds the static $g" ;; *) pass "AC-9 gate-run.sh does not hold $g" ;; esac
  done
fi
[ "$FAILS" -eq 0 ] || { fail "AC-9 the split is not there yet (gate-run.sh and shipfloor_core.gate): the delegation cannot be checked"; exit 1; }
wrapper="$(cat "$GATE")"
for g in gate_scope gate_forbidden gate_migration gate_acceptance_intact gate_test_plan gate_weight gate_qa_amend gate_qa_commit gate_fast; do
  case "$wrapper" in *"$g"*) fail "AC-9 scripts/gate.sh still holds the Bash $g" ;; *) pass "AC-9 scripts/gate.sh does not hold $g" ;; esac
done

# ---- build|red|green|stack are handed to lib/gate-run.sh, arguments unchanged
COPY="$(plugin_copy)"
mkdir -p "$COPY/scripts/lib"
cat > "$COPY/scripts/lib/gate-run.sh" <<'EOF'
#!/usr/bin/env bash
# test stub: records the arguments it is given and exits with the code in $GATE_RUN_CODE
printf '%s\n' "$@" > "$GATE_RUN_LOG"
exit "${GATE_RUN_CODE:-0}"
EOF
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
deleg() {  # deleg <label> <args...>: the wrapper hands exactly these args to gate-run.sh and returns its exit code
  local label="$1" got; shift
  rm -f "$T/run.log"
  GATE_RUN_LOG="$T/run.log" GATE_RUN_CODE=42 bash "$COPY/scripts/gate.sh" "$@" >"$T/out" 2>"$T/err"; got=$?
  if [ ! -e "$T/run.log" ]; then fail "AC-9 $label: scripts/lib/gate-run.sh was not run (exit $got, stderr: $(head -c 200 "$T/err"))"; return; fi
  [ "$got" = 42 ] && pass "AC-9 $label: the exit code of gate-run.sh is the gate's" || fail "AC-9 $label: exit $got, want 42"
  [ "$(cat "$T/run.log")" = "$(printf '%s\n' "$@")" ] && pass "AC-9 $label: gate-run.sh got the arguments unchanged" || fail "AC-9 $label: gate-run.sh got '$(tr '\n' ' ' < "$T/run.log")', want '$*'"
}
deleg "build" build "$base"
deleg "red" red web web/a.test.ts
deleg "green" green web web/a.test.ts
deleg "stack up" stack up owner-a
deleg "stack status" stack status
deleg "stack down" stack down owner-a
deleg "-C build" -C "$r" build "$base"
deleg "-C green" -C "$r" green web web/a.test.ts
deleg "an argument with a space" red web "web/a b.test.ts"

# the static gates are not handed to it, and they run in Python
cat > "$T/recpy" <<'EOF'
#!/usr/bin/env bash
# test python: logs its arguments, then runs the real one
printf '%s\n' "$*" >> "$RECPY_LOG"
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$T/recpy"
printf '**Weight:** light\n\n## Product\n' > spec.md
for args in "weight spec.md" "forbidden $base" "scope api $base" "test-plan spec.md" "qa-commit 1" "migration $base spec.md" "fast $base spec.md" "acceptance-intact $base" "acceptance-own $base x" "qa-amend 1"; do
  rm -f "$T/run.log" "$T/py.log"
  # shellcheck disable=SC2086
  REAL_PYTHON="$FACTORY_PYTHON" RECPY_LOG="$T/py.log" FACTORY_PYTHON="$T/recpy" GATE_RUN_LOG="$T/run.log" bash "$COPY/scripts/gate.sh" $args >"$T/out" 2>"$T/err"
  [ ! -e "$T/run.log" ] && pass "AC-9 '${args%% *}' is not handed to gate-run.sh" || fail "AC-9 '${args%% *}' was handed to gate-run.sh"
  if grep -q "sf.py gate ${args%% *}" "$T/py.log" 2>/dev/null; then pass "AC-9 '${args%% *}' runs through sf.py gate (Python)"; else fail "AC-9 '${args%% *}' did not run through 'sf.py gate' (python log: $(tr '\n' ' ' < "$T/py.log" 2>/dev/null | head -c 200))"; fi
done
# and the real wrapper ends the gate the same way as the Python entry
printf '**Weight:** light\n\n## Product\n' > spec.md
bash "$GATE" weight spec.md >"$T/wo" 2>"$T/we"; wc=$?
"$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" gate weight spec.md >"$T/po" 2>"$T/pe"; pc=$?
[ "$wc" = 0 ] && [ "$pc" = 0 ] && cmp -s "$T/wo" "$T/po" && cmp -s "$T/we" "$T/pe" && [ "$(cat "$T/pe")" = "gate weight: pass" ] && pass "AC-9 gate.sh weight and sf.py gate weight are the same gate" || fail "AC-9 wrapper exit $wc '$(cat "$T/we")' vs python exit $pc '$(cat "$T/pe")'"

# ---- the existing suites are not edited (checked against origin/main when this checkout has it)
top="$(git -C "$FACTORY_DIR" rev-parse --show-toplevel 2>/dev/null)"
mb=""; [ -z "$top" ] || mb="$(git -C "$top" merge-base origin/main HEAD 2>/dev/null)"
if [ -n "$mb" ]; then
  edited=""
  for f in $(git -C "$top" ls-tree -r --name-only "$mb" -- scripts/test | grep -E '/(gate-[a-z-]+|stack-[a-z-]+|dispatch-stepup|deploy-[a-z-]+|py-[a-z-]+)\.test\.sh$'); do
    git -C "$top" diff --quiet "$mb" -- "$f" || edited="$edited $f"
  done
  [ -z "$edited" ] && pass "AC-9 the existing gate, stack, dispatch-stepup, deploy and py suites are unedited" || fail "AC-9 these suites were edited:$edited"
else pass "AC-9 no origin/main here: the unedited-suites check is skipped"; fi
finish
