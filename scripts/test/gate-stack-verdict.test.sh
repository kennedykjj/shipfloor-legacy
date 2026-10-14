#!/usr/bin/env bash
# red and green on a needs_stack layer still say their verdict last on stderr and leave it in last-gate, in any language.
source "$(dirname "$0")/lib.sh"
GATE="$FACTORY_DIR/gate.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
export FACTORY_HOME="$(mktemp -d)"; bin="$(mktemp -d)"; L="$SHIPFLOOR_HOME/locks"
printf 'stacks: 2\nports: {base: 23000, span: 10}\nstack_wait: 10\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
cfg="$(mktemp)"; sed '/^stack:/d' "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
cat >> "$cfg" <<CFG
stack:
  up: 'echo "up \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  down: 'echo "down \$SHIPFLOOR_SLOT" >> "$bin/calls"'
  ports: [web, api]
  url: "http://localhost:{web}"
  health: "file:///$(nat "$bin")/health"
  reject: "Runtime Error"
  timeout: 5
CFG
export FACTORY_CONFIG="$cfg"
echo ok > "$bin/health"
# the e2e layer's runner: passes or fails by the mode file
cat > "$bin/pnpm" <<EOF
#!/usr/bin/env bash
if [ "\$(cat "$bin/mode")" = pass ]; then echo "  1 passed (1s)"; exit 0; fi
echo "AssertionError: expected 1 to be 2"; echo "  1 failed"; exit 1
EOF
chmod +x "$bin/pnpm"
export FACTORY_PNPM="$bin/pnpm"
r="$(new_repo)"; cd "$r"; mkdir -p web
run="$(mktemp -d)"

# run_gate <language> <gate> <runner mode>: sets G_ERR_LAST, G_LAST, G_RC
run_gate() {
  rm -f "$run/last-gate"; echo "$3" > "$bin/mode"
  env FACTORY_LANGUAGE="$1" SHIPFLOOR_RUN_LOCK="$run" bash "$GATE" "$2" e2e web/e2e/a.spec.ts 2> "$bin/err" >/dev/null; G_RC=$?
  G_ERR_LAST="$(tail -n 1 "$bin/err")"; G_LAST="$(cat "$run/last-gate" 2>/dev/null)"
}
tab="$(printf '\t')"
for lang in en pt-BR; do
  # green passes
  run_gate "$lang" green pass
  [ "$G_RC" -eq 0 ] && pass "AC-2/$lang green pass exits 0" || fail "AC-2/$lang green pass exit $G_RC"
  [ "$G_ERR_LAST" = "gate green: pass" ] && pass "AC-2/$lang green says pass last" || fail "AC-2/$lang green pass last stderr line: '$G_ERR_LAST'"
  [ "$G_LAST" = "green${tab}pass" ] && pass "AC-2/$lang green pass in last-gate" || fail "AC-2/$lang green pass last-gate: '$G_LAST'"
  # green fails
  run_gate "$lang" green fail
  [ "$G_RC" -eq 1 ] && pass "AC-2/$lang green fail exits 1" || fail "AC-2/$lang green fail exit $G_RC"
  [ "$G_ERR_LAST" = "gate green: FAIL (exit 1)" ] && pass "AC-2/$lang green says FAIL last" || fail "AC-2/$lang green fail last stderr line: '$G_ERR_LAST'"
  [ "$G_LAST" = "green${tab}FAIL" ] && pass "AC-2/$lang green FAIL in last-gate" || fail "AC-2/$lang green fail last-gate: '$G_LAST'"
  # red passes (the runner fails by assertion)
  run_gate "$lang" red fail
  [ "$G_RC" -eq 0 ] && pass "AC-2/$lang red pass exits 0" || fail "AC-2/$lang red pass exit $G_RC"
  [ "$G_ERR_LAST" = "gate red: pass" ] && pass "AC-2/$lang red says pass last" || fail "AC-2/$lang red pass last stderr line: '$G_ERR_LAST'"
  [ "$G_LAST" = "red${tab}pass" ] && pass "AC-2/$lang red pass in last-gate" || fail "AC-2/$lang red pass last-gate: '$G_LAST'"
  # red fails (the runner passes: the tests prove nothing)
  run_gate "$lang" red pass
  [ "$G_RC" -eq 1 ] && pass "AC-2/$lang red fail exits 1" || fail "AC-2/$lang red fail exit $G_RC"
  [ "$G_ERR_LAST" = "gate red: FAIL (exit 1)" ] && pass "AC-2/$lang red says FAIL last" || fail "AC-2/$lang red fail last stderr line: '$G_ERR_LAST'"
  [ "$G_LAST" = "red${tab}FAIL" ] && pass "AC-2/$lang red FAIL in last-gate" || fail "AC-2/$lang red fail last-gate: '$G_LAST'"
done

# AC-3: English and pt-BR behave the same
run_gate en green pass; en_out="$G_RC|$G_ERR_LAST|$G_LAST"
run_gate pt-BR green pass; pt_out="$G_RC|$G_ERR_LAST|$G_LAST"
[ "$en_out" = "$pt_out" ] && pass "AC-3 green pass is the same in en and pt-BR" || fail "AC-3 en='$en_out' pt-BR='$pt_out'"
run_gate en red pass; en_out="$G_RC|$G_ERR_LAST|$G_LAST"
run_gate pt-BR red pass; pt_out="$G_RC|$G_ERR_LAST|$G_LAST"
[ "$en_out" = "$pt_out" ] && pass "AC-3 red FAIL is the same in en and pt-BR" || fail "AC-3 en='$en_out' pt-BR='$pt_out'"
finish
