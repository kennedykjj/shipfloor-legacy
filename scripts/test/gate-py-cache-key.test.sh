#!/usr/bin/env bash
# #166 (PY-13), AC-6: the key of a recorded pass covers the gate's code: a pass recorded before an upgrade is not
# reused once any file under shipfloor_core/ or sf.py changes (or gate.sh, as before). A copy of scripts/ stands for the
# installed factory; its build leaves a mark outside the repository, so whether it ran is counted, not inferred.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
unset SHIPFLOOR_GATE_FRESH   # lib.sh sets it so the other tests keep running the command; this file tests the cache
M="$T/marks"; mkdir -p "$M"
cfg="$T/factory.yml"
sed -e "s|^    build: '\"\${FACTORY_PNPM:-pnpm}\" exec tsc.*|    build: 'echo b >> \"$M/build\"'|" \
    -e "s|^    test: '\"\${FACTORY_PNPM:-pnpm}\" exec vitest run.*|    test: 'echo t >> \"$M/green\"; echo \" Tests  1 passed (1)\"'|" \
    "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
grep -q "$M/build" "$cfg" && grep -q "$M/green" "$cfg" && pass "AC-6 (control) the config's web layer leaves marks" || fail "AC-6 could not build the config"
export FACTORY_CONFIG="$cfg" FACTORY_HOME; FACTORY_HOME="$(mktemp -d)"
COPY="$(plugin_copy)/scripts"; G="$COPY/gate.sh"
r="$(new_repo)"; cd "$r"; base="$(git rev-parse HEAD)"; mkdir -p web; echo x > web/a.ts; git add -A; git commit -qm c1
n() { [ -f "$M/$1" ] && wc -l < "$M/$1" | tr -d ' ' || echo 0; }
step() {  # step <want build runs> <want green runs> <label>: build and green through the copy, then count
  bash "$G" build "$base" >/dev/null 2>&1; bash "$G" green web web/a.test.ts >/dev/null 2>&1
  [ "$(n build) $(n green)" = "$1 $2" ] && pass "AC-6 $3" || fail "AC-6 $3: build ran $(n build) times, green $(n green), want $1 and $2"
}

step 1 1 "(control) the first build and green run"
step 1 1 "(control) an unchanged factory reuses both passes"
printf '\n# an upgrade that changes nothing else\n' >> "$COPY/shipfloor_core/text.py"
step 2 2 "a changed file under shipfloor_core/ invalidates the passes recorded before"
step 2 2 "...and the new passes are reused"
printf '\n# an upgrade\n' >> "$COPY/shipfloor_core/gate/context.py"
step 3 3 "a changed file in a sub-package of shipfloor_core/ invalidates them"
printf '"""a new module"""\n' > "$COPY/shipfloor_core/added.py"
step 4 4 "a file added under shipfloor_core/ invalidates them"
rm -f "$COPY/shipfloor_core/added.py"
step 5 5 "a file removed from shipfloor_core/ invalidates them"
printf '\n# an upgrade\n' >> "$COPY/sf.py"
step 6 6 "a changed sf.py invalidates them"
printf '\n# an upgrade\n' >> "$G"
step 7 7 "a changed gate.sh still invalidates them"
mkdir -p "$COPY/shipfloor_core/__pycache__"; echo junk > "$COPY/shipfloor_core/__pycache__/text.cpython-311.pyc"
step 7 7 "a __pycache__ under shipfloor_core/ is not the code: the passes stay"
cp -r "$COPY" "$T/second-copy"
bash "$T/second-copy/gate.sh" build "$base" >/dev/null 2>&1
[ "$(n build)" = 7 ] && pass "AC-6 another copy with the same content reuses the pass (the key is the content, not the path)" || fail "AC-6 a same-content copy ran the build again"
finish
