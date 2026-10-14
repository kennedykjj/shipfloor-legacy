#!/usr/bin/env bash
# #166 (PY-13), AC-4: build, red and green, ported to shipfloor_core/gate/run.py, behave as the Bash gate.sh kept as
# test/fixtures/gate.bash.sh (#165). Each scenario runs twice, each time with fresh fake runners and a fresh repo built the same
# way (fixed commit dates, so the same shas): on the fixture (in a copy of scripts/), then on scripts/gate.sh. The
# records (exit code, stdout, stderr with the verdict, what the runners were called with, <lock>/last-gate) must match
# once the side's own paths are written out.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"

[ -f "$FACTORY_DIR/test/fixtures/gate.bash.sh" ] && grep -q '^gate_green()' "$FACTORY_DIR/test/fixtures/gate.bash.sh" \
  && pass "AC-4 the Bash gate.sh (build/red/green included) is kept as test/fixtures/gate.bash.sh" || fail "AC-4 no Bash fixture test/fixtures/gate.bash.sh"
[ -f "$FACTORY_DIR/shipfloor_core/gate/run.py" ] && pass "AC-4 shipfloor_core/gate/run.py exists" || fail "AC-4 no shipfloor_core/gate/run.py"

# the Bash side: a copy of scripts/ whose gate.sh is the fixture
COPY="$(plugin_copy)"; cp "$FACTORY_DIR/test/fixtures/gate.bash.sh" "$COPY/scripts/gate.sh"
mkdir -p "$T/rec"

FIX="$FACTORY_DIR/test/fixture/factory.yml"
WEB_RAN="    ran: 'Tests +[1-9][0-9]* passed'"
CFG_RETRY="$T/retry.yml"; sed "s/^\(    ran: 'Tests +\[1-9\]\[0-9\]\* passed'\)$/\1\n    retry: 1/" "$FIX" > "$CFG_RETRY"
CFG_INSTALL="$T/install.yml"
sed "s/^\(    ran: 'Tests +\[1-9\]\[0-9\]\* passed'\)$/\1\n    install: 'echo installing; echo \"install ran\" >> \"\$B\/calls\"; [ ! -e \"\$B\/broken\" ]'/" "$FIX" > "$CFG_INSTALL"
CFG_BADPAT="$T/badpat.yml"; sed "s/^    ran: 'Tests +\[1-9\]\[0-9\]\* passed'$/    ran: 'a('/" "$FIX" > "$CFG_BADPAT"
grep -q 'retry: 1' "$CFG_RETRY" && grep -q 'install ran' "$CFG_INSTALL" && grep -q "ran: 'a('" "$CFG_BADPAT" \
  && pass "AC-4 the scenario configs are built" || fail "AC-4 could not build the scenario configs"

mkfakes() {  # mkfakes <dir>: mvn and pnpm that log their call and answer from <dir>/<name>.out and .rc (.flaky: fail once)
  local n
  for n in mvn pnpm; do
    cat > "$1/$n" <<'EOF'
#!/usr/bin/env bash
me="${0##*/}"; d="${0%/*}"
printf '%s|%s|NO_COLOR=%s FORCE_COLOR=%s|%s\n' "$me" "$*" "${NO_COLOR-}" "${FORCE_COLOR-}" "${PWD##*/}" >> "$d/calls"
if [ -e "$d/$me.flaky" ]; then rm -f "$d/$me.flaky"; echo "first try broke"; exit 1; fi
cat "$d/$me.out" 2>/dev/null; exit "$(cat "$d/$me.rc" 2>/dev/null || echo 0)"
EOF
    chmod +x "$1/$n"
  done
}
out() { printf '%s\n' "$3" > "$B/$1.out"; echo "$2" > "$B/$1.rc"; }  # out <runner> <exit> <output>
lines() { local i; for i in $(seq 1 "$2"); do echo "$1 $i"; done; }   # lines <text> <n>
repo() {  # repo [noweb]: a fresh repo, base <- one commit changing api/ and web/ (or api/ only); cwd is the repo
  R="$(new_repo)"; cd "$R" || exit 99; base="$(git rev-parse HEAD)"
  mkdir -p api; echo x > api/A.kt; [ "${1:-}" = noweb ] || { mkdir -p web; echo y > web/a.ts; }
  git add -A; git commit -qm change
}
gate() {  # gate <args...>: the side's gate, recorded
  local rc
  rm -f "$H/lock/last-gate"
  case "$SIDE" in bash) bash "$COPY/scripts/gate.sh" "$@" ;; *) bash "$FACTORY_DIR/gate.sh" "$@" ;; esac > "$H/o" 2> "$H/e"; rc=$?
  { echo "=== gate $*"; echo "exit $rc"; echo "--- stdout"; cat "$H/o"; echo "--- stderr"; cat "$H/e"
    echo "--- calls"; cat "$B/calls" 2>/dev/null; echo "--- last-gate"; cat "$H/lock/last-gate" 2>/dev/null; } >> "$REC"
  rm -f "$B/calls"
}

scenario_build() {
  out mvn 0 "BUILD SUCCESS"; out pnpm 0 "ok"; gate build "$base"
  out mvn 1 "Tests run: 3, Failures: 1"; gate build "$base"
  gate build nosuchrev; gate build
  export FACTORY_CONFIG="$CFG_RETRY"; out mvn 0 "BUILD SUCCESS"; touch "$B/pnpm.flaky"; gate build "$base"
  touch "$B/pnpm.flaky"; touch "$B/pnpm.flaky"; out pnpm 1 "tsc: error"; gate build "$base"
}
scenario_install() {
  export FACTORY_CONFIG="$CFG_INSTALL"; out mvn 0 "BUILD SUCCESS"; out pnpm 0 " Tests  1 passed (1)"
  gate green web web/a.test.ts; gate green web web/a.test.ts; gate build "$base"
  echo more > web/b.ts; git add -A; git commit -qm more; touch "$B/broken"
  gate green web web/a.test.ts; gate build "$base"; gate red web web/a.test.ts
}
scenario_red() {
  out mvn 1 "$( echo "[INFO] running"; lines "org.opentest4j.AssertionFailedError: expected: <429> but was: <200> at" 25; echo "[INFO] done")"
  gate red api RateLimitFilterTest
  out pnpm 1 "$(lines "src/a.ts: error TS2304: Cannot find name" 7; echo "AssertionError: expected 1 to be 2")"; gate red web lib/a.test.ts
  out mvn 0 "BUILD SUCCESS"; gate red api T
  out mvn 1 "something else broke"; gate red api T
  gate red api; gate red nolayer T
  out pnpm 1 "AssertionError: expected 'a' to be 'b'"; gate red web 'a b;$(touch pwned) "q"'
  [ -e pwned ] && echo "the selector ran as shell code" >> "$REC"
  out pnpm 1 "  Received: 3"; gate red web x
}
scenario_green() {
  out pnpm 0 " Tests  1 passed (1)"; gate green web web/a.test.ts
  out pnpm 1 "$(lines "failing line" 30)"; gate green web web/a.test.ts
  out pnpm 0 "nothing ran"; gate green web web/a.test.ts
  gate green web; gate green; gate green nolayer x
  out mvn 0 "Tests run: 4, Failures: 0"; gate green api 'Foo*Test'
  export FACTORY_CONFIG="$CFG_RETRY"; touch "$B/pnpm.flaky"; out pnpm 0 " Tests  1 passed (1)"; gate green web web/a.test.ts
  gate red web web/a.test.ts
  touch "$B/pnpm.flaky"; out pnpm 1 "still failing"; gate green web web/a.test.ts
}
scenario_patterns() {
  export FACTORY_CONFIG="$CFG_BADPAT"; out pnpm 0 " Tests  1 passed (1)"; gate green web x; gate red web x
}
scenario_dirs() {
  cd "$H" && repo noweb; out pnpm 0 " Tests  1 passed (1)"; gate green web x; gate red web x
  local r="$R"; cd /; out pnpm 0 " Tests  1 passed (1)"; gate -C "$r" green api x; gate -C /no/such/dir green web x
  cd "$r"; gate -C "$r" build "$base"
}
scenario_language() {
  export FACTORY_LANGUAGE=pt-BR
  out pnpm 1 "$(lines "failing line" 3)"; gate green web web/a.test.ts
  out pnpm 0 "BUILD"; gate red web x; gate green web; gate build nosuchrev
  out mvn 1 "broken"; gate build "$base"
}

norm() { sed -e "s|$H|<H>|g" -e "s|$B|<B>|g" -e "s|$R|<R>|g" -e "s|$COPY/scripts|<S>|g" -e "s|$FACTORY_DIR|<S>|g"; }
run_side() {  # run_side <scenario> <bash|py>
  local sc="$1"
  ( SIDE="$2"; H="$T/$2/$1"; rm -rf "$H"; mkdir -p "$H/bin" "$H/lock"; B="$H/bin"; mkfakes "$B"; REC="$T/rec/$sc.$2.raw"; : > "$REC"
    export B FACTORY_MVN="$B/mvn" FACTORY_PNPM="$B/pnpm" SHIPFLOOR_RUN_LOCK="$H/lock"
    repo; "scenario_$sc"; norm < "$REC" > "$T/rec/$sc.$2" )
}
compare() {  # compare <scenario> <label>
  run_side "$1" bash; run_side "$1" py
  if [ -s "$T/rec/$1.py" ] && diff -q "$T/rec/$1.bash" "$T/rec/$1.py" >/dev/null; then pass "AC-4 $2: the same as the Bash version"
  else fail "AC-4 $2 differs from the Bash version (< Bash, > Python):
$(diff "$T/rec/$1.bash" "$T/rec/$1.py" | head -40)"; fi
}

compare build "build: changed layers only, a failing build, bad revisions, retry and 'flaky:'"
compare install "deps: installed once per layer content, exit 3 when the install fails"
compare red "red: assertion lines (20 at most), setup errors (5 lines), passing or unclear tests, the selector as an argument"
compare green "green: pass, failure with the last 20 lines, nothing ran, missing selector or layer, retry and 'flaky:'"
compare patterns "a layer pattern grep -E refuses is exit 2"
compare dirs "a missing layer directory, -C <worktree> and a -C that cannot be entered"
compare language "stderr in the project's language, stdout and the verdict in English"
grep -q 'RateLimitFilterTest' "$T/rec/red.py" && [ "$(grep -c 'AssertionFailedError' "$T/rec/red.py")" -ge 20 ] \
  && pass "AC-4 (control) the red record holds the runner's assertion lines" || fail "AC-4 red record: $(head -30 "$T/rec/red.py")"
grep -q 'flaky: web web/a.test.ts' "$T/rec/green.py" && grep -q 'flaky: web build' "$T/rec/build.py" \
  && pass "AC-4 (control) the records hold the flaky lines" || fail "AC-4 no flaky line in the records"
grep -q 'gate: install failed in web/' "$T/rec/install.py" && pass "AC-4 (control) the install record holds the failure" || fail "AC-4 install record: $(cat "$T/rec/install.py")"
grep -q 'NO_COLOR=1 FORCE_COLOR=0' "$T/rec/green.py" && pass "AC-4 (control) the runner gets NO_COLOR=1 FORCE_COLOR=0" || fail "AC-4 runner env not in the record"
finish
