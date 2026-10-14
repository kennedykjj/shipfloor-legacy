#!/usr/bin/env bash
# #166 (PY-13), AC-5: a recorded pass answers `green` (and `build`) on the same clean tree with
# "<gate>: reused the pass on <sha12> recorded <time>; nothing ran", before any install or stack; no cache with
# SHIPFLOOR_GATE_FRESH=1, an empty FACTORY_HOME, a dirty worktree or a store inside the worktree; records older than
# 14 days are pruned when a pass is recorded. Whether a command ran is counted by marks outside the repository.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT
unset SHIPFLOOR_GATE_FRESH   # lib.sh sets it so the other tests keep running the command; this file tests the cache
GATE="$FACTORY_DIR/gate.sh"
M="$T/marks"; mkdir -p "$M"
stubs="$T/stubs"; mkdir -p "$stubs"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"; chmod +x "$stubs/lsof"; export PATH="$stubs:$PATH"
printf 'stacks: 1\nports: {base: 26400, span: 10}\nstack_wait: 5\nstack_stale: 90\nstack_hold_max: 2700\n' > "$SHIPFLOOR_HOME/config.yml"

# the fixture: web builds and tests leave a mark, web and e2e install leave one, the stack's up leaves one
cfg="$T/factory.yml"
while IFS= read -r line; do
  case "$line" in
    stack:*) printf '%s\n' "stack: {up: 'echo up >> \"$M/up\"', down: 'true', ports: [web], url: 'http://localhost:{web}'}" ;;
    *"exec tsc"*) printf '%s\n' "    build: 'echo b >> \"$M/build\"'" ;;
    *"exec vitest run"*) printf '%s\n' "    test: 'echo t >> \"$M/green\"; echo \" Tests  1 passed (1)\"'" "    install: 'echo i >> \"$M/install\"'" ;;
    *"exec playwright test"*) printf '%s\n' "    test: 'echo e >> \"$M/e2e\"; echo \" 1 passed\"'" "    install: 'echo i >> \"$M/install\"'" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$FACTORY_DIR/test/fixture/factory.yml" > "$cfg"
export FACTORY_CONFIG="$cfg"
n() { [ -f "$M/$1" ] && wc -l < "$M/$1" | tr -d ' ' || echo 0; }
counts() { echo "build=$(n build) green=$(n green) e2e=$(n e2e) install=$(n install) up=$(n up)"; }
fresh() {  # fresh: a new home, marks and repo (base <- c1 changing web/); cwd is the repo
  export FACTORY_HOME; FACTORY_HOME="$(mktemp -d)"; rm -f "$M"/*
  r="$(new_repo)"; cd "$r" || exit 1; base="$(git rev-parse HEAD)"
  mkdir -p web; echo x > web/a.ts; git add -A; git commit -qm c1; head="$(git rev-parse HEAD)"
}
store() { ls "$FACTORY_HOME/gate-passes" 2>/dev/null | wc -l | tr -d ' '; }

# ---- reuse: before any install or stack
fresh
bash "$GATE" green web web/a.test.ts >/dev/null 2>&1; bash "$GATE" green e2e web/e2e/a.spec.ts >/dev/null 2>&1; bash "$GATE" build "$base" >/dev/null 2>&1
before="$(counts)"
[ "$before" = "build=1 green=1 e2e=1 install=1 up=1" ] && pass "AC-5 (control) the first runs ran: $before" || fail "AC-5 first runs: $before"
for args in "green web web/a.test.ts" "green e2e web/e2e/a.spec.ts" "build $base"; do
  g="${args%% *}"
  err="$(bash "$GATE" $args 2>&1 >"$T/out")"; code=$?
  first="$(printf '%s\n' "$err" | sed -n 1p)"
  [ "$code" = 0 ] && [[ "$first" =~ ^$g:\ reused\ the\ pass\ on\ ${head:0:12}\ recorded\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\;\ nothing\ ran$ ]] \
    && pass "AC-5 $g ($args) says it reused the pass on <sha12> recorded <time>; nothing ran" || fail "AC-5 $args: exit $code: $err"
  [ "$(printf '%s\n' "$err" | sed -n 2p)" = "gate $g: pass" ] && [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 2 ] \
    && pass "AC-5 $g: then only its verdict" || fail "AC-5 $g stderr: $err"
  [ ! -s "$T/out" ] && pass "AC-5 $g: nothing on stdout" || fail "AC-5 $g stdout: $(cat "$T/out")"
done
[ "$(counts)" = "$before" ] && pass "AC-5 a reused pass runs nothing: no build, no test, no install, no stack up" || fail "AC-5 after reuse: $(counts), before: $before"
bash "$GATE" stack status | grep -q '^0	free' && pass "AC-5 no slot is left leased" || fail "AC-5 status: $(bash "$GATE" stack status | tr '\n' ' ')"

# ---- no cache: SHIPFLOOR_GATE_FRESH=1, empty FACTORY_HOME, dirty worktree, store inside the worktree
SHIPFLOOR_GATE_FRESH=1 bash "$GATE" green web web/a.test.ts >/dev/null 2>&1
[ "$(n green)" = 2 ] && pass "AC-5 SHIPFLOOR_GATE_FRESH=1 runs the tests" || fail "AC-5 FRESH=1: green=$(n green)"
FACTORY_HOME="" bash "$GATE" green web web/a.test.ts >/dev/null 2>&1; code=$?
[ "$code" = 0 ] && [ "$(n green)" = 3 ] && [ ! -e gate-passes ] && [ ! -e /gate-passes ] && pass "AC-5 an empty FACTORY_HOME runs the tests and records nothing" || fail "AC-5 empty FACTORY_HOME: exit $code, green=$(n green)"
echo dirt > web/untracked.ts
bash "$GATE" green web web/a.test.ts >/dev/null 2>&1; s1="$(store)"; bash "$GATE" green web web/a.test.ts >/dev/null 2>&1
[ "$(n green)" = 5 ] && [ "$(store)" = "$s1" ] && pass "AC-5 a dirty worktree runs the tests every time and records nothing" || fail "AC-5 dirty: green=$(n green), store $s1 -> $(store)"
rm -f web/untracked.ts
inside="$r/.home"; mkdir -p "$inside"; echo .home >> .git/info/exclude
FACTORY_HOME="$inside" bash "$GATE" green web web/a.test.ts >/dev/null 2>&1; FACTORY_HOME="$inside" bash "$GATE" green web web/a.test.ts >/dev/null 2>&1
[ "$(n green)" = 7 ] && [ -z "$(ls "$inside/gate-passes" 2>/dev/null)" ] && pass "AC-5 a store inside the worktree is not used" || fail "AC-5 store inside: green=$(n green), $(ls "$inside/gate-passes" 2>/dev/null)"
ln -s "$r" "$T/link-to-repo"; mkdir -p "$r/.home2"; echo .home2 >> .git/info/exclude
FACTORY_HOME="$T/link-to-repo/.home2" bash "$GATE" green web web/a.test.ts >/dev/null 2>&1
[ -z "$(ls "$r/.home2/gate-passes" 2>/dev/null)" ] && pass "AC-5 ...also when FACTORY_HOME reaches it through a symlink" || fail "AC-5 store inside through a symlink was used"

# ---- a failing gate records nothing; recording prunes records older than 14 days
fresh
mkdir -p "$FACTORY_HOME/gate-passes"
for a in old15:15 old30:30 new13:13 new1:1; do echo x > "$FACTORY_HOME/gate-passes/${a%%:*}"; touch -d "${a##*:} days ago" "$FACTORY_HOME/gate-passes/${a%%:*}"; done
FACTORY_MVN=false bash "$GATE" green api NoSuchTest >/dev/null 2>&1
[ "$(store)" = 4 ] && pass "AC-5 a failing gate records and prunes nothing" || fail "AC-5 failing gate: $(ls "$FACTORY_HOME/gate-passes" | tr '\n' ' ')"
bash "$GATE" green web web/a.test.ts >/dev/null 2>&1
left="$(ls "$FACTORY_HOME/gate-passes" | grep -v '^[0-9a-f]\{40\}$' | tr '\n' ' ')"
[ "$left" = "new1 new13 " ] && [ "$(store)" = 3 ] && pass "AC-5 recording a pass prunes the records older than 14 days" || fail "AC-5 prune left: $(ls "$FACTORY_HOME/gate-passes" | tr '\n' ' ')"
finish
