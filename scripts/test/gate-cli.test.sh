#!/usr/bin/env bash
# suite: integration
# gate.sh's contract through the real wrapper (the gates' decisions are py/gate_*.py's, in process): usage and exit
# codes 0/1/2/3, the verdict as stderr's last line and in <lock>/last-gate, -C and argv passed through untouched,
# SHIPFLOOR_PY handed down to the config queries, stderr in the project's language, stdout as data only.
# uses gate.sh sf.py lib/py.sh main.py changes.py report.sh
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"
FIX="$FACTORY_DIR/test/fixture/factory.yml"
run() { OUT="$("$@" 2>"$T/err")"; CODE=$?; ERR="$(cat "$T/err")"; }  # run <cmd...>: OUT, ERR, CODE
lastline() { printf '%s' "${1##*$'\n'}"; }
lock="$T/lock"; mkdir -p "$lock"

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
printf '**Weight:** light\n\n## Product\n' > "$T/good.md"; printf '# no weight\n' > "$T/bad.md"

run bash "$GATE" --help
[ "$CODE" = 0 ] && [ -z "$ERR" ] && case "$OUT" in "usage: gate.sh [-C <worktree>] <gate> ..."*) true ;; *) false ;; esac \
  && pass "--help: the usage on stdout, exit 0" || fail "--help: exit $CODE, stderr '$ERR'"
assert_exit 0 bash "$FACTORY_DIR/report.sh" --help   # kept from gate-build.test.sh until report's suite pins it
run bash "$GATE"
[ "$CODE" = 2 ] && [ -z "$OUT" ] && case "$ERR" in "usage: gate.sh"*) true ;; *) false ;; esac && [[ "$ERR" != *"gate "*": FAIL"* ]] \
  && pass "no argument: the usage on stderr, exit 2, no verdict" || fail "no argument: exit $CODE, stderr '$ERR'"
run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" bogus
[ "$CODE" = 2 ] && [ "$(lastline "$ERR")" = "gate bogus: FAIL (exit 2)" ] && [ "$(cat "$lock/last-gate")" = $'bogus\tFAIL' ] \
  && pass "an unknown command: exit 2, the FAIL verdict last and in last-gate" || fail "bogus: exit $CODE, stderr '$ERR'"
run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" weight "$T/good.md"
[ "$CODE" = 0 ] && [ "$ERR" = "gate weight: pass" ] && [ "$(cat "$lock/last-gate")" = $'weight\tpass' ] \
  && pass "a pass: exit 0, 'gate weight: pass' and last-gate" || fail "pass: exit $CODE, stderr '$ERR'"
run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" weight "$T/bad.md"
[ "$CODE" = 1 ] && [ "$(lastline "$ERR")" = "gate weight: FAIL (exit 1)" ] && [ "$(cat "$lock/last-gate")" = $'weight\tFAIL' ] \
  && pass "a block: exit 1, the FAIL verdict last and in last-gate" || fail "block: exit $CODE, stderr '$ERR'"

# -C and the arguments reach the gate as they were given
mkdir -p web; echo x > web/a.ts
cd "$T"
assert_exit 0 bash "$GATE" -C "$r" scope web "$base"
assert_exit 1 bash "$GATE" -C "$r" scope api "$base"
run bash "$GATE" -C "$T/missing" weight "$T/good.md"
[ "$CODE" = 2 ] && [ "$ERR" = "gate: cannot enter '$T/missing'" ] && pass "-C into a missing folder: exit 2, said, no verdict" || fail "-C missing: exit $CODE, '$ERR'"
cd "$r"; rm -rf web
bin="$T/bin"; mkdir -p "$bin"
printf '#!/usr/bin/env bash\necho "$# ${@: -1}" >> "%s/args"\necho "AssertionError: expected 1 to be 2"; exit 1\n' "$bin" > "$bin/pnpm"; chmod +x "$bin/pnpm"
mkdir -p web; sel='a b;$(touch pwned) "q"'
assert_exit 0 env FACTORY_PNPM="$bin/pnpm" bash "$GATE" red web "$sel"
[ "$(cat "$bin/args")" = "4 $sel" ] && [ ! -e pwned ] && [ ! -e web/pwned ] && pass "the selector reaches the runner as one argument, never as shell code" || fail "selector: $(cat "$bin/args")"

# no project: exit 2 from the wrapper's run, no verdict
run env -u FACTORY_CONFIG SHIPFLOOR_HOME="$T/nohome" bash "$GATE" weight "$T/good.md"
[ "$CODE" = 2 ] && [[ "$ERR" == *"is not in a registered project"* ]] && [[ "$ERR" != *"gate weight:"* ]] \
  && pass "a folder in no registered project: exit 2, said, no verdict" || fail "unresolved: exit $CODE, '$ERR'"

# the python a caller hands down (SHIPFLOOR_PY) answers the config queries, though lib/py.sh replaces it
cat > "$T/fakepy" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = gate-fast ] && { printf 'x\0'; exit 0; }; done
exec "$FACTORY_PYTHON" "$@"
EOF
chmod +x "$T/fakepy"
run env SHIPFLOOR_PY="$T/fakepy" bash "$GATE" fast "$base" "$T/good.md"
[ "$CODE" = 2 ] && [[ "$ERR" == *"gate: config query failed: gate-fast"* ]] && [ "$(lastline "$ERR")" = "gate fast: FAIL (exit 2)" ] \
  && pass "SHIPFLOOR_PY handed down answers the gate's config queries" || fail "SHIPFLOOR_PY: exit $CODE, '$ERR'"

# exit 3: infrastructure (a layer install that fails)
cfg="$T/install.yml"; sed "s|^\(    ran: 'Tests +\[1-9\]\[0-9\]\* passed'\)$|\1\n    install: 'false'|" "$FIX" > "$cfg"
grep -q "install: 'false'" "$cfg" || fail "could not add install to the fixture"
run env FACTORY_CONFIG="$cfg" SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" green web web/a.test.ts
[ "$CODE" = 3 ] && [ "$(lastline "$ERR")" = "gate green: INFRA (exit 3)" ] && [ "$(cat "$lock/last-gate")" = $'green\tINFRA' ] && [ -z "$OUT" ] \
  && pass "infrastructure: exit 3, the INFRA verdict last and in last-gate, nothing on stdout" || fail "INFRA: exit $CODE, '$ERR'"

# the project's language on stderr, the verdict in English; stdout carries only data
git checkout -q -b feat/13-x; mkdir -p api/src/test
echo test > api/src/test/ATest.kt; git add -A; git commit -qm "test(x): acceptance tests for #13"; qa="$(git rev-parse HEAD)"
echo weakened > api/src/test/ATest.kt; git commit -qam weaken
run env FACTORY_LANGUAGE=pt-BR bash "$GATE" acceptance-intact "$qa"
[ "$CODE" = 1 ] && [[ "$ERR" == *"acceptance-intact: os testes de aceitação mudaram depois do commit do QA"* ]] && [ -z "$OUT" ] \
  && [ "$(lastline "$ERR")" = "gate acceptance-intact: FAIL (exit 1)" ] && pass "pt-BR: stderr translated, the verdict in English, stdout empty" || fail "pt-BR: exit $CODE, '$ERR'"
run env FACTORY_LANGUAGE=pt-BR bash "$GATE" qa-commit 13
[ "$CODE" = 0 ] && [ "$OUT" = "$qa" ] && [ "$ERR" = "gate qa-commit: pass" ] && pass "qa-commit: the sha alone on stdout" || fail "qa-commit: exit $CODE, '$OUT' / '$ERR'"
finish
