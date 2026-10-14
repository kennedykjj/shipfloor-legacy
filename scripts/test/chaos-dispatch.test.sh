#!/usr/bin/env bash
# suite: end-to-end
# #173 (RES-01) violent failures and the next cycle. Stubs only (a fake claude, deploy, gh and gate command); the
# processes killed with SIGKILL are the stubs' and the supervisors that hold the locks.
#   AC-3  a launch, a deploy or a gate killed: the next cycle leaves no lock without a live process and no card in a
#         WIP column without a live run or a block (the lock is stale once it is past FACTORY_LOCK_TTL: the test lets
#         the time pass by dating the dead run's info back, as dispatch-lock.test.sh does)
#   AC-4  an orphan lock (dead pid) or an orphan index.lock: cleared, and the cycle goes on
#   AC-5  two cycles at once: each card launched at most once, no lock or temp file left
# The invariant itself is py/chaos_invariant.py. A "reused pid" lock (a live process that is not the run) is not here:
# dispatch-lock.test.sh pins that a live pid past the TTL keeps its lock.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/deploy-lib.sh"   # lib.sh, and the base repo of the deploy.sh cases
D="$FACTORY_DIR/dispatch.sh"
MD="$FACTORY_DIR/shipfloor-dispatch.sh"
GATE="$FACTORY_DIR/gate.sh"
INV="$FACTORY_DIR/test/py/chaos_invariant.py"
BASE_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"
HOLDS=(); GOS=()   # a run holds while its hold file exists, and waits for its go file to appear
cleanup() { local h; for h in "${HOLDS[@]:-}"; do [ -n "$h" ] && rm -f "$h"; done; for h in "${GOS[@]:-}"; do [ -n "$h" ] && touch "$h"; done; return 0; }  # releases every held run
trap cleanup EXIT
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! kill -0 "$1" 2>/dev/null; }
dead_pid() { sh -c ':' & local p=$!; wait "$p"; echo "$p"; }
age_file() { "$FACTORY_PYTHON" -I -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
invariant() {  # invariant <name> <args...>: chaos_invariant.py must print nothing
  local name="$1" out; shift
  out="$("$FACTORY_PYTHON" -I -B "$INV" "$@" 2>&1)" && pass "$name" || fail "$name: $out"
}
count_of() { local n; n="$(grep -cx -- "$2" "$1" 2>/dev/null)"; echo "${n:-0}"; }

fresh() {  # fresh: a new machine home with one project, "shop"; the board, claude and deploy are stubs
  T="$(mktemp -d)"; HOLDS+=("$T/hold"); touch "$T/hold"; export T
  export SHIPFLOOR_HOME="$(mktemp -d)" FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_CONTROL_REFRESH=0 FACTORY_CONFIG="$BASE_CONFIG"
  export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_PROJECT=shop FAKE_GH_DIR="$(mktemp -d)" FACTORY_GH="$FACTORY_DIR/test/fake-gh"
  unset FACTORY_LOCK_TTL FACTORY_REPO SHIPFLOOR_DISPATCH FAKE_GH_FAIL_AT FAKE_GH_FAIL_CMD
  export Q_REF= Q_DEV= Q_PROD= O_COD= W_CV=0
  mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks" "$FACTORY_HOME/logs"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$SHIPFLOOR_HOME/registry.tsv"
  printf 'pool: 8\nstages: {refine: 4, develop: 4, validate: 4, deploy: 1}\n' > "$SHIPFLOOR_HOME/config.yml"
  cat > "$T/board" <<'EOB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "eligible Ready for Refinement") for n in ${Q_REF:-}; do echo "$n"; done ;;
  "eligible Ready for Dev") for n in ${Q_DEV:-}; do echo "$n"; done ;;
  "eligible Ready for Prod") for n in ${Q_PROD:-}; do echo "$n"; done ;;
  "eligible Coding") for n in ${O_COD:-}; do echo "$n"; done ;;
  "count Coding") echo "${W_CV:-0}" ;;
  "count "*) echo 0 ;;
  *) echo ;;
esac
EOB
  # a run: it notes its pid and the prompt, then holds until the test lets it go
  cat > "$T/claude" <<'EOC'
#!/usr/bin/env bash
p="$(cat)"; echo "$$" > "$T/agent.pid"; echo "$p" >> "$T/launched"
n=0; while [ -e "$T/hold" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
EOC
  cat > "$T/deploy" <<'EOD'
#!/usr/bin/env bash
echo "$$" > "$T/agent.pid"; echo "/sf:deploy $1" >> "$T/launched"
n=0; while [ -e "$T/hold" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
EOD
  chmod +x "$T/board" "$T/claude" "$T/deploy"
  export FACTORY_BOARD="$T/board" FACTORY_CLAUDE="$T/claude" FACTORY_DEPLOY="$T/deploy"
  : > "$T/launched"
}
cycle() { bash "$D" >"$T/cycle.out" 2>&1; }
lock_info_pid() { local w; read -r w _ < "$FACTORY_HOME/locks/$1.lock/info" 2>/dev/null && [ -n "$w" ] && echo "$w"; }
agent_pid() { [ -s "$T/agent.pid" ] && cat "$T/agent.pid"; }
no_locks() { [ -z "$(find "$FACTORY_HOME/locks" -mindepth 1 -maxdepth 1 -name '*.lock' 2>/dev/null)" ]; }
settle() { rm -f "$T/hold"; wait_for "the runs to end" no_locks; }
launched_n() { count_of "$T/launched" "$1"; }

# ---------------------------------------------------------------- AC-3: a launch killed, a deploy killed
# kill_case <name> <lock name> <prompt line> <card> <board file line or ->: cycle 1 starts the run; the supervisor that
# holds the lock and the agent stub are killed (SIGKILL); the run's time passes (info dated back); cycle 2 runs.
kill_case() {
  local name="$1" lock="$2" prompt="$3" card="$4" row="$5" sup agent old
  cycle; local crc=$?
  wait_for "the run's lock to name its supervisor" lock_info_pid "$lock"
  wait_for "the agent stub to start" agent_pid
  sup="$(lock_info_pid "$lock")"; agent="$(agent_pid)"
  [ "$crc" = 0 ] && alive "$sup" && pass "AC-3 $name: cycle 1 started the run and left (supervisor $sup alive)" || fail "AC-3 $name: cycle 1 exit $crc, supervisor '$sup': $(cat "$T/cycle.out")"
  kill -9 "$sup" "$agent" 2>/dev/null
  wait_for "the supervisor to die" dead "$sup"; wait_for "the agent to die" dead "$agent"
  [ -d "$FACTORY_HOME/locks/$lock.lock" ] && pass "AC-3 $name: the kill leaves the lock behind (nobody could remove it)" || fail "AC-3 $name: no lock left to test the next cycle on"
  old="$(( $(date +%s) - 20000 ))"; echo "$sup $old $card" > "$FACTORY_HOME/locks/$lock.lock/info"   # three hours later
  rm -f "$T/agent.pid"
  cycle; crc=$?
  [ "$crc" = 0 ] && pass "AC-3 $name: cycle 2 exits 0" || fail "AC-3 $name: cycle 2 exits $crc: $(cat "$T/cycle.out")"
  wait_for "cycle 2 to start the card again" agent_pid
  [ "$(launched_n "$prompt")" = 2 ] && pass "AC-3 $name: cycle 2 started the card again ($prompt)" || fail "AC-3 $name: '$prompt' launched $(launched_n "$prompt") times, want 2"
  local new; new="$(lock_info_pid "$lock")"
  [ -n "$new" ] && [ "$new" != "$sup" ] && alive "$new" && pass "AC-3 $name: the lock is held by a live process again, not the dead one" || fail "AC-3 $name: lock pid '$new' (dead run was $sup)"
  if [ "$row" != - ]; then printf '%b' "$row" > "$T/board.tsv"; invariant "AC-3 $name: no stale lock, no WIP card without a run or a block, no leftover" --no-dashboard --board "$T/board.tsv" "$SHIPFLOOR_HOME"
  else invariant "AC-3 $name: no stale lock, no leftover" --no-dashboard "$SHIPFLOOR_HOME"; fi
  settle
  invariant "AC-3 $name: once the run ends nothing is left behind" --no-dashboard "$SHIPFLOOR_HOME"
}
fresh; O_COD=42; W_CV=1; export O_COD W_CV
kill_case "launch killed" develop-42 "/sf:develop 42" 42 '42\tCoding\n'
fresh; Q_PROD=7; export Q_PROD
kill_case "deploy run killed" deploy-7 "/sf:deploy 7" 7 -

# ---------------------------------------------------------------- AC-3: deploy.sh itself killed
# deploy.sh holds deploysh-<n>.lock (its pid); a slow gh stands in the way so the kill lands inside it. The next deploy
# takes the dead lock over, finishes the card, and leaves no lock or temp file.
setup
cat > "$T/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in "pr list"*"--state open"*) echo "$$" > "$T/gh.pid"; n=0; while [ ! -e "$T/go" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done ;; esac
exec bash "$FACTORY_DIR/test/fake-gh-deploy" "$@"
EOF
chmod +x "$T/gh"; export FACTORY_GH="$T/gh"; export T FACTORY_DIR
GOS+=("$T/go")
(cd "$repo" && bash "$DEP" 7 > "$T/out1" 2>&1; :) & DP=$!   # the trailing : keeps the subshell, so the kill is not reported as a job's
wait_for "deploy.sh to reach gh" test -s "$T/gh.pid"
wait_for "deploy.sh to write its lock" test -s "$FACTORY_HOME/locks/deploysh-7.lock/info"
read -r dpid _ < "$FACTORY_HOME/locks/deploysh-7.lock/info"; gpid="$(cat "$T/gh.pid")"
kill -9 "$dpid" "$gpid" 2>/dev/null; { wait "$DP"; } 2>/dev/null
wait_for "deploy.sh to die" dead "$dpid"
[ -d "$FACTORY_HOME/locks/deploysh-7.lock" ] && pass "AC-3 deploy.sh killed: its lock is left behind" || fail "AC-3 deploy.sh killed: no lock left"
[ ! -e "$FG/merged" ] && pass "AC-3 deploy.sh killed: nothing was merged yet" || fail "AC-3 deploy.sh killed: the PR was merged"
touch "$T/go"
code="$(run 7)"
[ "$code" = 0 ] && pass "AC-3 deploy.sh killed: the next deploy takes the dead lock over and finishes the card" || fail "AC-3 deploy.sh killed: the next deploy exit $code: $(cat "$T/out")"
[ ! -d "$FACTORY_HOME/locks/deploysh-7.lock" ] && pass "AC-3 deploy.sh killed: no lock left after the next deploy" || fail "AC-3 deploy.sh killed: the lock is still there"
invariant "AC-3 deploy.sh killed: no stale lock, no leftover temp file" --no-dashboard --no-run-tmp "$FACTORY_HOME"

# ---------------------------------------------------------------- AC-3: a gate killed
# A build that holds; both the gate and its build are killed. No pass is recorded for it, no verdict claims one, no
# temp file is left, and the next gate runs the build again and records its pass.
unset SHIPFLOOR_GATE_FRESH
export FACTORY_HOME="$(mktemp -d)" FACTORY_CONFIG="$(mktemp)"; MARKS="$(mktemp -d)"; LOCK="$FACTORY_HOME/locks/validate-9.lock"
mkdir -p "$LOCK"; echo "$$ $(date +%s) 9" > "$LOCK/info"
while IFS= read -r line; do
  case "$line" in
    *"exec tsc"*) printf '%s\n' "    build: 'echo \$\$ > \"$MARKS/build.pid\"; echo \$PPID > \"$MARKS/gate.pid\"; echo b >> \"$MARKS/build\"; n=0; while [ ! -e \"$MARKS/go\" ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done' " ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$BASE_CONFIG" > "$FACTORY_CONFIG"
GOS+=("$MARKS/go")
r="$(new_repo)"; git -C "$r" config user.email t@t; git -C "$r" config user.name t
base="$(git -C "$r" rev-parse HEAD)"; mkdir -p "$r/web"; echo y > "$r/web/c.ts"; git -C "$r" add -A; git -C "$r" commit -qm c1
(cd "$r" && SHIPFLOOR_RUN_LOCK="$LOCK" bash "$GATE" build "$base" >"$MARKS/out1" 2>&1; :) & GP=$!
wait_for "the build to start" test -s "$MARKS/gate.pid"
wait_for "the build to note its pid" test -s "$MARKS/build.pid"
kill -9 "$(cat "$MARKS/gate.pid")" "$(cat "$MARKS/build.pid")" 2>/dev/null; { wait "$GP"; } 2>/dev/null
wait_for "the gate to die" dead "$(cat "$MARKS/gate.pid")"
[ -z "$(ls "$FACTORY_HOME/gate-passes" 2>/dev/null | grep -v '^\.')" ] && pass "AC-3 gate killed: no pass is recorded for it" || fail "AC-3 gate killed: recorded $(ls "$FACTORY_HOME/gate-passes")"
case "$(cat "$LOCK/last-gate" 2>/dev/null)" in *pass*) fail "AC-3 gate killed: last-gate says pass" ;; *) pass "AC-3 gate killed: last-gate does not claim a pass" ;; esac
invariant "AC-3 gate killed: no leftover temp file" --no-dashboard --no-run-tmp "$FACTORY_HOME"
touch "$MARKS/go"
(cd "$r" && SHIPFLOOR_RUN_LOCK="$LOCK" bash "$GATE" build "$base" >"$MARKS/out2" 2>&1); grc=$?
[ "$grc" = 0 ] && pass "AC-3 gate killed: the next gate passes" || fail "AC-3 gate killed: the next gate exit $grc: $(cat "$MARKS/out2")"
[ "$(wc -l < "$MARKS/build" | tr -d ' ')" = 2 ] && pass "AC-3 gate killed: the next gate ran the build again, it did not reuse a pass" || fail "AC-3 gate killed: the build ran $(wc -l < "$MARKS/build" | tr -d ' ') times, want 2"
[ "$(cat "$LOCK/last-gate" 2>/dev/null)" = "$(printf 'build\tpass')" ] && pass "AC-3 gate killed: last-gate now records the pass" || fail "AC-3 gate killed: last-gate is '$(cat "$LOCK/last-gate" 2>/dev/null)'"
[ "$(ls "$FACTORY_HOME/gate-passes" | grep -vc '^\.')" = 1 ] && pass "AC-3 gate killed: one pass is recorded" || fail "AC-3 gate killed: passes: $(ls "$FACTORY_HOME/gate-passes")"
invariant "AC-3 gate killed: no leftover temp file after the next gate" --no-dashboard --no-run-tmp "$FACTORY_HOME"
export SHIPFLOOR_GATE_FRESH=1

# ---------------------------------------------------------------- AC-4: orphan locks
# a lock whose pid is dead, past the TTL: removed, and the card starts on a new lock held by a live process
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100
dp="$(dead_pid)"; mkdir -p "$FACTORY_HOME/locks/develop-54.lock"; echo "$dp $(( $(date +%s) - 400 )) 54" > "$FACTORY_HOME/locks/develop-54.lock/info"
cycle; crc=$?
wait_for "the card to start on the orphan's slot" agent_pid
[ "$crc" = 0 ] && [ "$(launched_n '/sf:develop 54')" = 1 ] && pass "AC-4 a dead pid past the TTL: the cycle clears the lock and starts the card" || fail "AC-4 dead pid: exit $crc, launched $(launched_n '/sf:develop 54') times: $(cat "$T/cycle.out")"
new="$(lock_info_pid develop-54)"; [ -n "$new" ] && [ "$new" != "$dp" ] && alive "$new" && pass "AC-4 the new lock names a live process" || fail "AC-4 the lock names '$new' (the orphan's pid was $dp)"
settle
invariant "AC-4 dead pid: no lock or temp file left" --no-dashboard "$SHIPFLOOR_HOME"
# ... and gh down for that cycle (the dependency read fails): nothing starts and no stale lock is left; once gh is back
# the next cycle starts the card
fresh; export Q_DEV=54 FACTORY_LOCK_TTL=100
mkdir -p "$FACTORY_HOME/locks/develop-54.lock"; echo "$dp $(( $(date +%s) - 400 )) 54" > "$FACTORY_HOME/locks/develop-54.lock/info"
FAKE_GH_FAIL_CMD='dependencies/blocked_by' cycle; crc=$?
[ "$(launched_n '/sf:develop 54')" = 0 ] && pass "AC-4 dead lock, gh failing: the card is not started on a dependency it could not read" || fail "AC-4 dead lock, gh failing: launched $(launched_n '/sf:develop 54') times (exit $crc)"
[ ! -d "$FACTORY_HOME/locks/develop-54.lock" ] && pass "AC-4 dead lock, gh failing: the stale lock is gone anyway" || fail "AC-4 dead lock, gh failing: the stale lock is still there"
cycle; wait_for "the card to start once gh is back" agent_pid
[ "$(launched_n '/sf:develop 54')" = 1 ] && pass "AC-4 dead lock: the next cycle, gh back, starts the card" || fail "AC-4 dead lock: launched $(launched_n '/sf:develop 54') times after gh came back"
settle
invariant "AC-4 dead lock, gh failing: no lock or temp file left" --no-dashboard "$SHIPFLOOR_HOME"
# a lock with no pid at all and no info, old by its folder's time
fresh; export Q_DEV=55 FACTORY_LOCK_TTL=100
mkdir -p "$FACTORY_HOME/locks/develop-55.lock"; age_file "$FACTORY_HOME/locks/develop-55.lock" 400
cycle; wait_for "the card to start" agent_pid
[ "$(launched_n '/sf:develop 55')" = 1 ] && pass "AC-4 a lock with no info, old by its time: cleared, the card starts" || fail "AC-4 no-info lock: launched $(launched_n '/sf:develop 55') times"
settle
# deploy.sh's own lock with a dead pid: the next deploy takes it over
setup; mkdir -p "$FACTORY_HOME/locks/deploysh-7.lock"; echo "$(dead_pid) $(date +%s)" > "$FACTORY_HOME/locks/deploysh-7.lock/info"
code="$(run 7)"
[ "$code" = 0 ] && [ ! -d "$FACTORY_HOME/locks/deploysh-7.lock" ] && pass "AC-4 deploy.sh's lock of a dead pid: the deploy takes it over, finishes, leaves no lock" || fail "AC-4 deploy.sh dead lock: exit $code: $(cat "$T/out")"

# ---------------------------------------------------------------- AC-4: an orphan index.lock in the control checkout
cyc_setup() {  # cyc_setup: a new machine home for shipfloor-dispatch.sh; its dispatch.sh is a stub that notes the project
  unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT FACTORY_BOARD FACTORY_CLAUDE FACTORY_DEPLOY FACTORY_CONTROL_REFRESH \
    FACTORY_LOCK_TTL FAKE_GH_DIR FACTORY_GH SHIPFLOOR_STALE_LOCK_MIN SHIPFLOOR_CYCLE_STALE_MIN
  export SHIPFLOOR_HOME="$(mktemp -d)" SHIPFLOOR_LOCK_RETRY_S=0; tmp="$(mktemp -d)"; HOLDS+=("$tmp/hold")
  printf '#!/usr/bin/env bash\necho "$FACTORY_PROJECT" >> "%s/ran"\nn=0; while [ -e "%s/hold" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done\n' "$tmp" "$tmp" > "$tmp/dispatch"
  chmod +x "$tmp/dispatch"; export SHIPFLOOR_DISPATCH="$tmp/dispatch"; : > "$tmp/ran"
}
project() {  # project <slug>: a repo with a remote whose main carries .shipfloor/factory.yml; R and REMOTE name them
  local slug="$1"
  REMOTE="$(mktemp -d)"; git init -q --bare "$REMOTE"; R="$(new_repo)"
  mkdir -p "$R/.shipfloor"; sed "s/name: shop/name: $slug/" "$BASE_CONFIG" > "$R/.shipfloor/factory.yml"
  git -C "$R" add -A; git -C "$R" commit -qm cfg
  git -C "$R" remote add origin "$REMOTE"; git -C "$R" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$R" "$SHIPFLOOR_HOME/projects/$slug/wt" >> "$SHIPFLOOR_HOME/registry.tsv"
}
cyc_setup; project shop; rm -f "$tmp/hold"
bash "$MD" >/dev/null 2>&1                                  # the first cycle makes the control checkout
C="$SHIPFLOOR_HOME/projects/shop/control"; ILOCK="$(git -C "$C" rev-parse --absolute-git-dir)/index.lock"
sed -i.bak "s/number: [0-9]*/number: 8/" "$R/.shipfloor/factory.yml"; rm -f "$R/.shipfloor/factory.yml.bak"; git -C "$R" commit -qam bump; git -C "$R" push -q origin main
: > "$ILOCK"; age_file "$ILOCK" 900; : > "$tmp/ran"          # a git that died 15 minutes ago left it; main moved on
bash "$MD" >"$tmp/out" 2>&1; crc=$?
[ ! -e "$ILOCK" ] && pass "AC-4 an orphan index.lock is removed" || fail "AC-4 the index.lock is still there: $(cat "$tmp/out")"
[ "$crc" = 0 ] && grep -qx shop "$tmp/ran" && pass "AC-4 ... and the cycle goes on: the project is dispatched, exit 0" || fail "AC-4 after the index.lock: exit $crc, ran '$(cat "$tmp/ran")': $(cat "$tmp/out")"
[ "$(git -C "$C" rev-parse HEAD)" = "$(git -C "$R" rev-parse origin/main)" ] && pass "AC-4 ... and the control checkout is at origin/main" || fail "AC-4 the control checkout did not move to origin/main"
invariant "AC-4 index.lock: nothing left, the dashboard reads the home" "$SHIPFLOOR_HOME"

# ---------------------------------------------------------------- AC-5: two cycles at once
# the machine cycle: dispatch.pid lets one in; the other records the overlap and stops
cyc_setup; project shop; touch "$tmp/hold"
bash "$MD" >"$tmp/out1" 2>&1 & PA=$!
bash "$MD" >"$tmp/out2" 2>&1 & PB=$!
other_done() { dead "$PA" || dead "$PB"; }
wait_for "one of the two cycles to stop" other_done
rm -f "$tmp/hold"; wait "$PA"; ra=$?; wait "$PB"; rb=$?
[ "$ra" = 0 ] && [ "$rb" = 0 ] && pass "AC-5 two machine cycles at once both exit 0" || fail "AC-5 machine cycles exit $ra and $rb"
[ "$(count_of "$tmp/ran" shop)" = 1 ] && pass "AC-5 the project was dispatched once, not twice" || fail "AC-5 the project was dispatched $(count_of "$tmp/ran" shop) times"
[ ! -e "$SHIPFLOOR_HOME/dispatch.pid" ] && pass "AC-5 dispatch.pid is gone after both" || fail "AC-5 dispatch.pid is left"
invariant "AC-5 machine cycles: no lock or temp file left" "$SHIPFLOOR_HOME"

# the project cycle: two dispatch.sh at once over two ready cards
fresh; export Q_DEV="26 27"
bash "$D" >"$T/c1.out" 2>&1 & PA=$!
bash "$D" >"$T/c2.out" 2>&1 & PB=$!
wait "$PA"; ra=$?; wait "$PB"; rb=$?
both_started() { [ "$(launched_n '/sf:develop 26')" -ge 1 ] && [ "$(launched_n '/sf:develop 27')" -ge 1 ]; }
wait_for "both cards to start" both_started
[ "$ra" = 0 ] && [ "$rb" = 0 ] && pass "AC-5 two project cycles at once both exit 0" || fail "AC-5 project cycles exit $ra and $rb: $(cat "$T/c1.out" "$T/c2.out")"
[ "$(launched_n '/sf:develop 26')" = 1 ] && [ "$(launched_n '/sf:develop 27')" = 1 ] && pass "AC-5 each card was launched exactly once" || fail "AC-5 launches: #26 $(launched_n '/sf:develop 26'), #27 $(launched_n '/sf:develop 27')"
settle
invariant "AC-5 project cycles: no lock or temp file left once the runs end" --no-dashboard "$SHIPFLOOR_HOME"
finish
