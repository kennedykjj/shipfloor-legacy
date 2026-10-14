#!/usr/bin/env bash
# Characterization of gate.sh's verdict line, exit codes and stdout (#158, AC-1). These pin what the Bash gate does
# today, before the Python port: every assertion passes against the current code.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)"; export TMPDIR="$T"
trap 'rm -rf "$T" "${LIBTMP[@]}"' EXIT
GATE="$FACTORY_DIR/gate.sh"
FIX="$FACTORY_DIR/test/fixture/factory.yml"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

bin="$(mktemp -d)"
# a lsof that finds nothing: the stack's port clean-up must never touch a real process of this machine
printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/lsof"; chmod +x "$bin/lsof"
export PATH="$bin:$PATH"
# the layer's runner: its behavior is the mode in $bin/mode
cat > "$bin/pnpm" <<EOF
#!/usr/bin/env bash
mode="\$(cat "$bin/mode" 2>/dev/null)"
case "\$mode" in
  red) echo "setup chatter"; echo "AssertionError: expected 1 to be 2"; echo " Tests  1 failed (1)"; exit 1 ;;
  green) echo " Tests  1 passed (1)" ;;
  flaky) if [ -e "$bin/once" ]; then echo " Tests  1 passed (1)"; exit 0; fi
         touch "$bin/once"; echo "AssertionError: expected 1 to be 2"; exit 1 ;;
  build) echo "building \$*" ;;
  buildflaky) if [ -e "$bin/once" ]; then echo "building \$*"; exit 0; fi
              touch "$bin/once"; echo boom; exit 1 ;;
esac
EOF
chmod +x "$bin/pnpm"
export FACTORY_PNPM="$bin/pnpm"
mode() { echo "$1" > "$bin/mode"; rm -f "$bin/once"; }

printf 'stacks: 2\nports: {base: 23000, span: 10}\nstack_wait: 3\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"
# config variants of the fixture: retry, install, and a stack whose up command is given
CFG_RETRY="$(mktemp)"; sed "s/^\(    ran: 'Tests +\[1-9\]\[0-9\]\* passed'\)$/\1\n    retry: 1/" "$FIX" > "$CFG_RETRY"
grep -q 'retry: 1' "$CFG_RETRY" && pass "AC-1 fixture layer gets retry: 1" || fail "AC-1 could not add retry to the fixture"
printf '#!/usr/bin/env bash\n[ ! -e "%s/broken" ]\n' "$bin" > "$bin/install"; chmod +x "$bin/install"
CFG_INSTALL="$(mktemp)"; sed "s|^\(    ran: 'Tests +\[1-9\]\[0-9\]\* passed'\)$|\1\n    install: 'bash \"$bin/install\"'|" "$FIX" > "$CFG_INSTALL"
grep -q 'install:' "$CFG_INSTALL" && pass "AC-1 fixture layer gets install" || fail "AC-1 could not add install to the fixture"
stack_cfg() {  # stack_cfg <file> <up command>
  sed '/^stack:/d' "$FIX" > "$1"
  printf 'stack:\n  up: %s\n  down: "true"\n  ports: [web]\n  url: "http://localhost:{web}"\n' "$2" >> "$1"
}
CFG_STACK="$(mktemp)"; stack_cfg "$CFG_STACK" "'true'"
CFG_STACKFAIL="$(mktemp)"; stack_cfg "$CFG_STACKFAIL" "'echo up exploded; false'"

r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"
mkdir -p web/e2e; echo a > web/a.test.ts; echo e > web/e2e/a.spec.ts; git add -A; git commit -qm web; base_web="$(git rev-parse HEAD)"
lock="$(mktemp -d)"

run() {  # run <cmd...>: OUT = stdout, ERR = stderr, CODE = exit code
  OUT="$("$@" 2>"$T/err")"; CODE=$?; ERR="$(cat "$T/err")"
}
lastline() { printf '%s' "${1##*$'\n'}"; }
lastgate() { cat "$lock/last-gate" 2>/dev/null; }

# ---- a gate that passes or blocks: the verdict is the last stderr line and is left in the run lock
printf '**Weight:** light\n\n## Product\n' > good.md; printf '# no weight\n' > bad.md
rm -f "$lock/last-gate"; run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" weight good.md
[ "$CODE" = 0 ] && [ "$(lastline "$ERR")" = "gate weight: pass" ] && pass "AC-1 a passing gate ends stderr with 'gate weight: pass'" || fail "AC-1 pass: exit $CODE, stderr: $ERR"
[ "$(lastgate)" = "$(printf 'weight\tpass')" ] && pass "AC-1 last-gate records 'weight<TAB>pass'" || fail "AC-1 last-gate: $(lastgate)"
rm -f "$lock/last-gate"; run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" weight bad.md
[ "$CODE" = 1 ] && [ "$(lastline "$ERR")" = "gate weight: FAIL (exit 1)" ] && pass "AC-1 a blocked gate ends stderr with 'gate weight: FAIL (exit 1)'" || fail "AC-1 block: exit $CODE, stderr: $ERR"
[ "$(lastgate)" = "$(printf 'weight\tFAIL')" ] && pass "AC-1 last-gate records 'weight<TAB>FAIL'" || fail "AC-1 last-gate: $(lastgate)"
rm -f "$lock/last-gate"; run bash "$GATE" weight good.md
[ ! -e "$lock/last-gate" ] && pass "AC-1 outside a factory run (no SHIPFLOOR_RUN_LOCK) no last-gate is written" || fail "AC-1 last-gate written without a run lock"

# ---- INFRA: a real gate whose install fails
mode green
touch "$bin/broken"; rm -f "$lock/last-gate"
run env FACTORY_CONFIG="$CFG_INSTALL" SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" green web web/a.test.ts
[ "$CODE" = 3 ] && pass "AC-1 a failing install is exit 3" || fail "AC-1 install failure: exit $CODE, stderr: $ERR"
[ "$(lastline "$ERR")" = "gate green: INFRA (exit 3)" ] && pass "AC-1 a failing install ends stderr with 'gate green: INFRA (exit 3)'" || fail "AC-1 last stderr line: $(lastline "$ERR")"
[ "$(lastgate)" = "$(printf 'green\tINFRA')" ] && pass "AC-1 last-gate records 'green<TAB>INFRA' for the install failure" || fail "AC-1 last-gate: $(lastgate)"
[ -z "$OUT" ] && pass "AC-1 an INFRA verdict puts nothing on stdout" || fail "AC-1 stdout on INFRA: $OUT"
rm -f "$bin/broken"

# ---- INFRA: a real gate whose layer's stack does not come up
rm -f "$lock/last-gate"
run env FACTORY_CONFIG="$CFG_STACKFAIL" SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" green e2e web/e2e/a.spec.ts
[ "$CODE" = 3 ] && pass "AC-1 a stack that does not come up is exit 3" || fail "AC-1 stack failure: exit $CODE, stderr: $ERR"
# Not pinned: the verdict line and last-gate of a gate that took a stack. stack_lease clears the EXIT trap that
# prints the verdict (trap - EXIT INT TERM), so today neither is written. Reported as a bug for PY-03.
case "$ERR" in *"stack: up failed:"*"up exploded"*) pass "AC-1 the stack failure shows the up log tail" ;; *) fail "AC-1 no up log tail in: $ERR" ;; esac

# ---- no verdict and no last-gate when resolve fails or -C fails
rm -f "$lock/last-gate"
run env -u FACTORY_CONFIG SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" weight good.md
[ "$CODE" = 2 ] && pass "AC-1 an unregistered project is exit 2" || fail "AC-1 unresolved: exit $CODE, stderr: $ERR"
case "$ERR" in *"is not in a registered project"*) pass "AC-1 resolve says the project is not registered" ;; *) fail "AC-1 unresolved message: $ERR" ;; esac
case "$ERR" in *"gate weight:"*) fail "AC-1 a verdict after a failed resolve: $ERR" ;; *) pass "AC-1 no verdict line after a failed resolve" ;; esac
[ ! -e "$lock/last-gate" ] && pass "AC-1 no last-gate after a failed resolve" || fail "AC-1 last-gate after a failed resolve: $(lastgate)"
run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" -C "$T/does-not-exist" weight good.md
[ "$CODE" = 2 ] && pass "AC-1 -C into a missing directory is exit 2" || fail "AC-1 -C: exit $CODE, stderr: $ERR"
case "$ERR" in *"gate: cannot enter '$T/does-not-exist'"*) pass "AC-1 -C says it cannot enter the directory" ;; *) fail "AC-1 -C message: $ERR" ;; esac
case "$ERR" in *"gate weight:"*) fail "AC-1 a verdict after a failed -C: $ERR" ;; *) pass "AC-1 no verdict line after a failed -C" ;; esac
[ ! -e "$lock/last-gate" ] && pass "AC-1 no last-gate after a failed -C" || fail "AC-1 last-gate after a failed -C: $(lastgate)"
run bash "$GATE" -C "$r" weight good.md
[ "$CODE" = 0 ] && pass "AC-1 -C into a real directory runs the gate there" || fail "AC-1 -C into the repo: exit $CODE, stderr: $ERR"

# ---- help and no argument
run bash "$GATE" help
[ "$CODE" = 0 ] && pass "AC-1 help exits 0" || fail "AC-1 help: exit $CODE"
case "$OUT" in "usage: gate.sh"*) pass "AC-1 help prints the usage to stdout" ;; *) fail "AC-1 help stdout: $OUT" ;; esac
[ -z "$ERR" ] && pass "AC-1 help prints nothing on stderr" || fail "AC-1 help stderr: $ERR"
run bash "$GATE" --help; [ "$CODE" = 0 ] && [ -n "$OUT" ] && pass "AC-1 --help is help" || fail "AC-1 --help: exit $CODE"
run bash "$GATE"
[ "$CODE" = 2 ] && pass "AC-1 no argument exits 2" || fail "AC-1 no argument: exit $CODE"
case "$ERR" in "usage: gate.sh"*) pass "AC-1 no argument prints the usage to stderr" ;; *) fail "AC-1 no argument stderr: $ERR" ;; esac
[ -z "$OUT" ] && pass "AC-1 no argument prints nothing on stdout" || fail "AC-1 no argument stdout: $OUT"
case "$ERR" in *"gate "*": FAIL"*) fail "AC-1 no argument printed a verdict: $ERR" ;; *) pass "AC-1 no argument has no verdict line" ;; esac

# ---- an unknown command
rm -f "$lock/last-gate"; run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" bogus
[ "$CODE" = 2 ] && pass "AC-1 an unknown command exits 2" || fail "AC-1 unknown command: exit $CODE"
[ "$(lastline "$ERR")" = "gate bogus: FAIL (exit 2)" ] && pass "AC-1 an unknown command ends stderr with 'gate bogus: FAIL (exit 2)'" || fail "AC-1 last stderr line: $(lastline "$ERR")"
case "$ERR" in "usage: gate.sh"*) pass "AC-1 an unknown command prints the usage on stderr first" ;; *) fail "AC-1 unknown command stderr: $ERR" ;; esac
[ "$(lastgate)" = "$(printf 'bogus\tFAIL')" ] && pass "AC-1 last-gate records 'bogus<TAB>FAIL'" || fail "AC-1 last-gate: $(lastgate)"
[ -z "$OUT" ] && pass "AC-1 an unknown command prints nothing on stdout" || fail "AC-1 stdout: $OUT"

# ---- stdout carries only data, in every language (a non-English run sends stderr through the catalog, never stdout)
data_same() {  # data_same <label> <want stdout> <command...>
  local label="$1" want="$2" lang got; shift 2
  for lang in en pt-BR; do
    got="$(FACTORY_LANGUAGE=$lang "$@" 2>/dev/null)"
    if [ "$got" = "$want" ]; then pass "AC-1 $label: stdout is only the data ($lang)"; else fail "AC-1 $label ($lang): stdout '$got', want '$want'"; fi
  done
}

# the qa-commit sha
git checkout -q -b feat/14-x
echo t > web/b.test.ts; git add -A; git commit -qm "test(x): acceptance tests for #14"; qa="$(git rev-parse HEAD)"
data_same "qa-commit" "$qa" bash "$GATE" qa-commit 14
data_same "qa-commit --head" "$qa" bash "$GATE" qa-commit 14 --head

# the own: key of a card's own edit
echo edited > web/b.test.ts; git commit -qam "the card edits a test"
own="$(bash "$GATE" acceptance-own "$qa" web/b.test.ts 2>/dev/null)"
[[ "$own" =~ ^own:[0-9a-f]{40,64}$ ]] && pass "AC-1 acceptance-own prints 'own:<hash>' and nothing else" || fail "AC-1 acceptance-own stdout: '$own'"
data_same "acceptance-own" "$own" bash "$GATE" acceptance-own "$qa" web/b.test.ts
rm -f "$lock/last-gate"; run env SHIPFLOOR_RUN_LOCK="$lock" bash "$GATE" acceptance-own "$qa" web/b.test.ts
[ ! -e "$lock/last-gate" ] && [ -z "$ERR" ] && pass "AC-1 acceptance-own has no verdict line and no last-gate" || fail "AC-1 acceptance-own: stderr '$ERR'"

# red's assertion lines: the matching lines and nothing else
mode red
data_same "red" "AssertionError: expected 1 to be 2" bash "$GATE" red web web/a.test.ts

# flaky: from green and from build
mode flaky
data_same "green flaky" "flaky: web web/a.test.ts" env FACTORY_CONFIG="$CFG_RETRY" bash -c 'rm -f "$1/once"; exec bash "$2" green web web/a.test.ts' _ "$bin" "$GATE"
mode buildflaky
data_same "build flaky" "$(printf 'boom\nbuilding exec tsc --noEmit\nbuilding test\nflaky: web build')" \
  env FACTORY_CONFIG="$CFG_RETRY" bash -c 'rm -f "$1/once"; exec bash "$2" build "$3"' _ "$bin" "$GATE" "$base"
# build output
mode build
echo c > web/c.ts; git add -A; git commit -qm c
data_same "build output" "$(printf 'building exec tsc --noEmit\nbuilding test')" bash "$GATE" build "$base"

# the stack URL and the status TSV
run env FACTORY_CONFIG="$CFG_STACK" bash "$GATE" stack up owner-a
[ "$CODE" = 0 ] && [ "$OUT" = "http://localhost:23000" ] && pass "AC-1 stack up prints the URL and nothing else" || fail "AC-1 stack up: exit $CODE, stdout '$OUT', stderr '$ERR'"
# to a file, not $(...): in a non-English run the slot's heartbeat inherits the stdout pipe (fd 3) and a capturing
# caller would wait for the release (a bug, not pinned)
FACTORY_CONFIG="$CFG_STACK" FACTORY_LANGUAGE=pt-BR bash "$GATE" stack up owner-b > "$T/up.out" 2> "$T/up.err"
[ "$(cat "$T/up.out")" = "http://localhost:23010" ] && pass "AC-1 stack up prints only the URL in pt-BR" || fail "AC-1 stack up pt-BR: stdout '$(cat "$T/up.out")', stderr '$(cat "$T/up.err")'"
TAB=$'\t'
for lang in en pt-BR; do
  run env FACTORY_CONFIG="$CFG_STACK" FACTORY_LANGUAGE=$lang bash "$GATE" stack status
  mapfile -t lines <<< "$OUT"
  if [ "${#lines[@]}" = 3 ] && [[ "${lines[0]}" =~ ^0${TAB}busy${TAB}owner-a${TAB}[0-9]+${TAB}$ ]] \
     && [[ "${lines[1]}" =~ ^1${TAB}busy${TAB}owner-b${TAB}[0-9]+${TAB}$ ]] && [ "${lines[2]}" = "queue${TAB}0" ]; then
    pass "AC-1 stack status prints only the TSV ($lang)"
  else fail "AC-1 stack status ($lang): $OUT"; fi
done
bash "$GATE" stack down owner-a >/dev/null 2>&1; bash "$GATE" stack down owner-b >/dev/null 2>&1
finish
