#!/usr/bin/env bash
# build and green reuse a pass the factory itself recorded for the same commit and the same inputs
# (docs/superpowers/specs/2026-10-11-validate-does-not-rerun-a-gate-that-alre-design.md). Whether the layer's
# command ran is counted by a mark it appends to a file outside the repository, never inferred from the output.
source "$(dirname "$0")/lib.sh"
unset SHIPFLOOR_GATE_FRESH   # lib.sh sets it so the other tests keep running the command; this file tests the reuse
GATE="$FACTORY_DIR/gate.sh"
FIXTURE="$FACTORY_DIR/test/fixture/factory.yml"

mkcfg() {  # mkcfg <file> <marks dir>: the fixture, with the web layer's build and tests leaving a mark
  local out="$1" marks="$2" line
  while IFS= read -r line; do
    case "$line" in
      *"exec tsc"*)         printf '%s\n' "    build: 'echo b >> \"$marks/build\"; [ ! -e \"$marks/failflag\" ]'" ;;
      *"exec vitest run"*)  printf '%s\n' "    test: 'echo \"\$1\" >> \"$marks/green\"; echo \" Tests  1 passed (1)\"'" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$FIXTURE" > "$out"
}

scenario() {  # scenario: fresh home, marks, config and repo; c0 (base) <- c1 <- c2 (HEAD); cwd is the repo
  export FACTORY_HOME; FACTORY_HOME="$(mktemp -d)"
  MARKS="$(mktemp -d)"
  CFG="$(mktemp)"; mkcfg "$CFG" "$MARKS"; export FACTORY_CONFIG="$CFG"
  r="$(new_repo)"; cd "$r" || exit 1
  base="$(git rev-parse HEAD)"
  mkdir -p web; echo x > web/a.ts; echo t > web/a.test.ts; git add -A; git commit -qm c1; base2="$(git rev-parse HEAD)"
  echo y > web/c.ts; git add -A; git commit -qm c2
  head="$(git rev-parse HEAD)"
}

runs() { if [ -f "$MARKS/$1" ]; then wc -l < "$MARKS/$1" | tr -d ' '; else echo 0; fi; }
expect_runs() {  # expect_runs <mark> <want> <what>
  local got; got="$(runs "$1")"
  if [ "$got" = "$2" ]; then pass "$3"; else fail "$3: $got runs of the layer's command, want $2"; fi
}
stored() { ls "$FACTORY_HOME/gate-passes" 2>/dev/null | wc -l | tr -d ' '; }
build() { bash "$GATE" build "${1:-$base}" 2>&1; }
green() { bash "$GATE" green web "$1" 2>&1; }

# ---- AC-1 and AC-2: the same call on the same commit answers from the recorded pass, and says so
scenario
out1="$(build)"; code1=$?
[ "$code1" = 0 ] && pass "AC-1 first build passes" || fail "AC-1 first build failed (exit $code1): $out1"
expect_runs build 1 "AC-1 the first build runs the layer's build"
case "$out1" in *"reused the pass"*) fail "AC-2 the first call (a real run) says it reused a pass" ;; *) pass "AC-2 a real run does not claim a reuse" ;; esac
err="$(bash "$GATE" build "$base" 2>&1 >/dev/null)"; code2=$?
[ "$code2" = 0 ] && pass "AC-1 second build on the same commit passes" || fail "AC-1 second build failed (exit $code2): $err"
expect_runs build 1 "AC-1 build ran again on the same commit and arguments"
case "${err##*$'\n'}" in "gate build: pass") pass "AC-1 the verdict is still 'gate build: pass'" ;; *) fail "AC-1 last line is not 'gate build: pass': $err" ;; esac
[ "$(stored)" = 1 ] && pass "AC-1 one pass recorded under FACTORY_HOME/gate-passes" || fail "AC-1 $(stored) records under FACTORY_HOME/gate-passes, want 1"
rec="$(ls "$FACTORY_HOME/gate-passes" 2>/dev/null | head -1)"
if [ -n "$rec" ]; then
  line="$(cat "$FACTORY_HOME/gate-passes/$rec")"
  t="$(printf '%s' "$line" | cut -f1)"
  [ "$(printf '%s' "$line" | cut -f2)" = "$head" ] && [ "$(printf '%s' "$line" | cut -f3)" = build ] \
    && pass "AC-1 the record is '<time> <HEAD> build <args>', tab-separated" || fail "AC-1 record is not '<time>\\t<HEAD sha>\\tbuild\\t...': $line"
else
  t=""; fail "AC-1 no record file in FACTORY_HOME/gate-passes"
fi
sha12="$(printf '%s' "$head" | cut -c1-12)"
before="${err%$'\n'*}"
case "$err" in *$'\n'*) ;; *) before="" ;; esac
case "$before" in
  *"build: reused the pass on $sha12 recorded "*"; nothing ran"*) pass "AC-2 the reuse line names the commit" ;;
  *) fail "AC-2 no 'build: reused the pass on $sha12 recorded <time>; nothing ran' line before the verdict: $err" ;;
esac
[ -n "$t" ] && case "$before" in *"recorded $t;"*) pass "AC-2 the reuse line carries the time the pass was recorded" ;; *) fail "AC-2 the reuse line does not carry the recorded time '$t': $err" ;; esac

# ---- AC-3: another commit, other arguments, a moved base, a changed config: the command runs
scenario
build >/dev/null
echo z > web/d.ts; git add -A; git commit -qm c3
build >/dev/null
expect_runs build 2 "AC-3 build did not run on another commit"

scenario
build >/dev/null; build "$base2" >/dev/null
expect_runs build 2 "AC-3 build did not run with another base argument"

scenario
git update-ref refs/remotes/origin/main "$base"
build >/dev/null
git update-ref refs/remotes/origin/main "$head"
build >/dev/null
expect_runs build 2 "AC-3 build did not run after origin/main moved"
build >/dev/null
expect_runs build 2 "AC-3 build with origin/main unchanged reuses (control)"

scenario
build >/dev/null
printf '# changed\n' >> "$CFG"
build >/dev/null
expect_runs build 2 "AC-3 build did not run after the project config changed"

# ---- AC-4: a failed build is never reused
scenario
: > "$MARKS/failflag"
build >/dev/null; c1=$?
build >/dev/null; c2=$?
[ "$c1" = 1 ] && [ "$c2" = 1 ] && pass "AC-4 a failing build fails again" || fail "AC-4 exits $c1 and $c2, want 1 and 1"
expect_runs build 2 "AC-4 a failed build was not run again on the same commit"
[ "$(stored)" = 0 ] && pass "AC-4 a failed build records nothing" || fail "AC-4 $(stored) records after a failure, want 0"
rm -f "$MARKS/failflag"
build >/dev/null; c3=$?
[ "$c3" = 0 ] && pass "AC-4 the build passes once the command does" || fail "AC-4 exit $c3 after the command passes, want 0"
expect_runs build 3 "AC-4 the build after a failure runs"

# ---- AC-5: a file claiming a pass inside the worktree is ignored; a store inside the worktree is refused
scenario
build >/dev/null
legit="$FACTORY_HOME"
export FACTORY_HOME; FACTORY_HOME="$(mktemp -d)"   # a home that has never seen the pass
for d in gate-passes .shipfloor/gate-passes .shipfloor/projects/x/gate-passes; do
  mkdir -p "$r/$d"; cp "$legit/gate-passes/"* "$r/$d/"; printf '%s\n' "/${d%%/*}/" >> "$r/.git/info/exclude"
done
[ -z "$(git status --porcelain)" ] && pass "AC-5 the forged records leave the worktree clean (so only they are tested)" || fail "AC-5 worktree dirty: $(git status --porcelain)"
build >/dev/null
expect_runs build 2 "AC-5 a pass file copied inside the worktree was believed"
[ "$(stored)" = 1 ] && pass "AC-5 the gate records under its own home" || fail "AC-5 $(stored) records under FACTORY_HOME/gate-passes, want 1"

scenario
build >/dev/null
FACTORY_HOME="$r/.home"; mkdir -p "$FACTORY_HOME"; printf '/.home/\n' >> "$r/.git/info/exclude"
[ -z "$(git status --porcelain)" ] && pass "AC-5 a home inside the worktree, ignored by git, leaves it clean" || fail "AC-5 worktree dirty: $(git status --porcelain)"
build >/dev/null; build >/dev/null
expect_runs build 3 "AC-5 a gate-passes store inside the worktree was used (ran: only the first run outside it was counted)"
[ "$(ls "$r/.home/gate-passes" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && pass "AC-5 nothing recorded inside the worktree" || fail "AC-5 records written inside the worktree"

# ---- AC-6: green reuses per selector
scenario
green web/a.test.ts >/dev/null
out="$(green web/a.test.ts)"; code=$?
[ "$code" = 0 ] && pass "AC-6 the second green passes" || fail "AC-6 second green failed (exit $code): $out"
expect_runs green 1 "AC-6 green ran the same selector again on the same commit"
case "$out" in *"green: reused the pass on $(git rev-parse HEAD | cut -c1-12) recorded "*"; nothing ran"*) pass "AC-6 green says it reused a pass" ;; *) fail "AC-6 no 'green: reused the pass on ... recorded ...; nothing ran' line: $out" ;; esac
green web/other.test.ts >/dev/null
expect_runs green 2 "AC-6 a different selector did not run its tests"
green web/other.test.ts >/dev/null
expect_runs green 2 "AC-6 the second selector's own pass was not reused"

# ---- AC-7: tracked changes or untracked files not in the commit: the gate runs and records nothing
scenario
build >/dev/null
echo more >> web/a.ts
build >/dev/null
expect_runs build 2 "AC-7 build reused a pass with a tracked change in the worktree"
git checkout -q -- web/a.ts
echo n > web/new.ts
build >/dev/null
expect_runs build 3 "AC-7 build reused a pass with an untracked file in the worktree"
rm -f web/new.ts

scenario
echo more >> web/a.ts
build >/dev/null
[ "$(stored)" = 0 ] && pass "AC-7 a dirty worktree records no pass" || fail "AC-7 $(stored) records written from a dirty worktree, want 0"
git checkout -q -- web/a.ts
build >/dev/null
expect_runs build 2 "AC-7 the clean build after a dirty pass was answered by a pass the dirty run recorded"

# ---- AC-8: deploy's gates (fast, forbidden) run every time and record nothing; build with no record runs
scenario
out="$(bash "$GATE" fast "$base" /dev/null 2>&1)"; code=$?
out="$(bash "$GATE" fast "$base" /dev/null 2>&1)"; code2=$?
[ "$code" = "$code2" ] && pass "AC-8 fast answers the same twice (exit $code)" || fail "AC-8 fast exit $code then $code2 on one commit"
case "$out" in *"reused"*) fail "AC-8 fast reused a pass: $out" ;; *) pass "AC-8 fast never reuses" ;; esac
out="$(bash "$GATE" forbidden "$base" 2>&1)"; out="$(bash "$GATE" forbidden "$base" 2>&1)"; code=$?
case "$out" in *"reused"*) fail "AC-8 forbidden reused a pass: $out" ;; *) pass "AC-8 forbidden never reuses" ;; esac
[ "$code" = 0 ] && pass "AC-8 forbidden passes on the merged head" || fail "AC-8 forbidden failed (exit $code): $out"
[ "$(stored)" = 0 ] && pass "AC-8 fast and forbidden record nothing" || fail "AC-8 fast/forbidden wrote $(stored) records, want 0"
mkdir -p docs/engineering; echo f > docs/engineering/x.md; git add -A; git commit -qm forbidden
bash "$GATE" forbidden "$base" >/dev/null 2>&1; fc=$?
[ "$fc" = 1 ] && pass "AC-8 forbidden still blocks on a forbidden change" || fail "AC-8 forbidden exit $fc on a forbidden change, want 1"
build >/dev/null; bc=$?
[ "$bc" = 0 ] && pass "AC-8 build on a commit no gate passed on passes" || fail "AC-8 build exit $bc"
expect_runs build 1 "AC-8 build on a commit with no record did not run"
finish
