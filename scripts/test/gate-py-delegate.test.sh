#!/usr/bin/env bash
# AC-9 of #165: gate.sh is a wrapper. The static gates (scope, forbidden, acceptance-intact, acceptance-own, qa-commit,
# qa-amend, migration, fast, test-plan, weight) are Python (shipfloor_core.gate.main, through sf.py gate);
# since #166 build|red|green|stack are too (gate/run.py), and scripts/lib/gate-run.sh is gone.
# The existing gate-*, stack-lock, dispatch-stepup, deploy-* and py-* suites are not edited by the card.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
MAINPID=$BASHPID  # only this shell cleans up, never a subshell that holds the trap
trap '[ "$BASHPID" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"

# ---- the pieces exist (#166 ported build|red|green|stack too: scripts/lib/gate-run.sh is gone)
[ ! -e "$FACTORY_DIR/lib/gate-run.sh" ] && pass "AC-9 scripts/lib/gate-run.sh is gone (#166)" || fail "AC-9 scripts/lib/gate-run.sh still exists"
[ -d "$FACTORY_DIR/shipfloor_core/gate" ] && [ -f "$FACTORY_DIR/shipfloor_core/gate/__init__.py" ] && [ -f "$FACTORY_DIR/shipfloor_core/gate/main.py" ] && pass "AC-9 shipfloor_core/gate/ has __init__.py and main.py" || fail "AC-9 scripts/shipfloor_core/gate/{__init__,main}.py do not exist"
for m in changes scope acceptance migration spec run; do
  [ -f "$FACTORY_DIR/shipfloor_core/gate/$m.py" ] && pass "AC-9 shipfloor_core/gate/$m.py exists" || fail "AC-9 scripts/shipfloor_core/gate/$m.py does not exist"
done
"$FACTORY_PYTHON" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import shipfloor_core.gate as g; sys.exit(0 if callable(getattr(g, "main", None)) else 1)' "$FACTORY_DIR" 2>"$T/imp" \
  && pass "AC-9 shipfloor_core.gate.main is importable and callable" || fail "AC-9 shipfloor_core.gate.main is not importable: $(tail -1 "$T/imp")"
"$FACTORY_PYTHON" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import shipfloor_core.gate as g; sys.exit(0 if g.main(["--help"]) == 0 else 1)' "$FACTORY_DIR" >/dev/null 2>&1 \
  && pass "AC-9 shipfloor_core.gate.main(['--help']) returns 0" || fail "AC-9 shipfloor_core.gate.main(['--help']) does not return 0"
wrapper="$(cat "$GATE")"
for g in gate_scope gate_forbidden gate_migration gate_acceptance_intact gate_test_plan gate_weight gate_qa_amend gate_qa_commit gate_fast; do
  case "$wrapper" in *"$g"*) fail "AC-9 scripts/gate.sh still holds the Bash $g" ;; *) pass "AC-9 scripts/gate.sh does not hold $g" ;; esac
done

# ---- every gate runs through sf.py gate, arguments unchanged (build|red|green|stack included, -C too)
COPY="$(plugin_copy)"
cat > "$T/recpy" <<'EOF'
#!/usr/bin/env bash
# test python: logs its arguments, one per line, then runs the real one
printf '%s\n' "$@" >> "$RECPY_LOG"
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$T/recpy"
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
deleg() {  # deleg <label> <args...>: the wrapper runs sf.py gate with exactly these args
  local label="$1"; shift
  rm -f "$T/py.log"
  REAL_PYTHON="$FACTORY_PYTHON" RECPY_LOG="$T/py.log" FACTORY_PYTHON="$T/recpy" bash "$COPY/scripts/gate.sh" "$@" >"$T/out" 2>"$T/err"
  [ "$(sed -n '/sf\.py$/,$p' "$T/py.log" 2>/dev/null | sed 1d | head -n $(( $# + 1 )))" = "$(printf '%s\n' gate "$@")" ] \
    && pass "AC-9 $label: sf.py gate got the arguments unchanged" || fail "AC-9 $label: python ran with '$(tr '\n' ' ' < "$T/py.log" 2>/dev/null)', want 'sf.py gate $*'"
}
deleg "build" build "$base"
deleg "red" red web web/a.test.ts
deleg "green" green web web/a.test.ts
deleg "stack status" stack status
deleg "stack down" stack down owner-a
deleg "-C build" -C "$r" build "$base"
deleg "-C green" -C "$r" green web web/a.test.ts
deleg "an argument with a space" red web "web/a b.test.ts"

# the static gates run in Python too
cat > "$T/recpy" <<'EOF'
#!/usr/bin/env bash
# test python: logs its arguments, then runs the real one
printf '%s\n' "$*" >> "$RECPY_LOG"
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$T/recpy"
printf '**Weight:** light\n\n## Product\n' > spec.md
for args in "weight spec.md" "forbidden $base" "scope api $base" "test-plan spec.md" "qa-commit 1" "migration $base spec.md" "fast $base spec.md" "acceptance-intact $base" "acceptance-own $base x" "qa-amend 1"; do
  rm -f "$T/py.log"
  # shellcheck disable=SC2086
  REAL_PYTHON="$FACTORY_PYTHON" RECPY_LOG="$T/py.log" FACTORY_PYTHON="$T/recpy" bash "$COPY/scripts/gate.sh" $args >"$T/out" 2>"$T/err"
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
  for f in $(git -C "$top" ls-tree -r --name-only "$mb" -- scripts/test | grep -E '/(gate-[a-z-]+|stack-[a-z-]+|dispatch-stepup|deploy-[a-z-]+|py-[a-z-]+)\.test\.sh$' \
             | grep -vE '/(gate-py-run-compat|stack-py-lease)\.test\.sh$'); do  # #166's own files, which its gate half extends
    git -C "$top" diff --quiet "$mb" -- "$f" || edited="$edited $f"
  done
  [ -z "$edited" ] && pass "AC-9 the existing gate, stack, dispatch-stepup, deploy and py suites are unedited" || fail "AC-9 these suites were edited:$edited"
else pass "AC-9 no origin/main here: the unedited-suites check is skipped"; fi
finish
