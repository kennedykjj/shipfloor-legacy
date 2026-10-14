#!/usr/bin/env bash
# shipfloor_core.project / shipfloor_core.text (#162) on a fixture state: each case builds a fresh state, runs the
# operation and checks what it printed (paths made relative to the state) and what it left on disk.
#   AC-4  resolve from a worktree, the resolve failure message, snapshot, the three tmp helpers, weight
#   AC-6  say('pt-BR', line) translates the catalog's lines, one line out per line in; no catalog: the text passes through
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; N=0
export GIT_TERMINAL_PROMPT=0

# ---- the Python side
cat > "$T/drv.py" <<'EOF'
import io, os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["PARITY_SCRIPTS"])
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")
try:
    from shipfloor_core import project, text
except Exception as e:
    sys.stderr.write("driver: shipfloor_core cannot be loaded: %s: %s\n" % (type(e).__name__, e))
    sys.exit(70)


def rc_of(r):
    if isinstance(r, bool):
        return 0 if r else 1
    if isinstance(r, int):
        return r
    return 0


def lines_of(r):
    if r is None:
        return []
    if isinstance(r, bytes):
        r = r.decode("utf-8")
    if isinstance(r, str):
        return [l for l in r.splitlines() if l]
    return [str(x) for x in r]


def field(r, key):
    v = os.environ.get("FACTORY_" + key)
    if v:
        return v
    if isinstance(r, dict):
        return str(r.get(key.lower(), "") or "")
    return str(getattr(r, key.lower(), "") or "")


op, args = sys.argv[1], sys.argv[2:]
out = []
err = io.StringIO()
real_out, real_err = sys.stdout, sys.stderr
cap = io.StringIO()
sys.stdout, sys.stderr = cap, err
rc = 0
r = None
try:
    if op == "resolve":
        r = project.resolve()
    elif op == "snapshot":
        r = project.snapshot()
    elif op == "stale":
        out = sorted(lines_of(project.stale_tmp()))
    elif op == "clean":
        project.clean_tmp(args[0])
    elif op == "sweep":
        r = project.sweep_tmp()
        out = sorted(lines_of(r) or lines_of(cap.getvalue()))
    elif op == "spec_weight":
        out = [str(project.spec_weight(args[0]))]
    elif op == "card_spec":
        out = [str(project.card_spec(args[0]) or "")]
    elif op == "card_weight":
        out = [str(project.card_weight(args[0]))]
    elif op == "say":
        for l in open(args[1], encoding="utf-8", newline="\n").read().split("\n"):
            if l == "" :
                continue
            s = text.say(args[0], l)
            if isinstance(s, bytes):
                s = s.decode("utf-8")
            out.append(s[:-1] if s.endswith("\n") else s)
except Exception as e:
    err.write(str(e) + "\n")
    rc = 1
finally:
    sys.stdout, sys.stderr = real_out, real_err

if op == "resolve":
    if rc == 0 and not field(r, "PROJECT"):
        rc = 1
    print("rc=%d" % rc)
    if rc == 0:
        for k in ("PROJECT", "REPO", "MAIN", "HOME", "WT_ROOT", "CONFIG"):
            print("%s=%s" % (k, field(r, k)))
elif op == "snapshot":
    print("rc=%d" % (rc or rc_of(r)))
else:
    for l in out:
        print(l)
sys.stderr.write(err.getvalue())
EOF

# ---- a state: a registered project, its control checkout, worktrees for cards, a tmp/ folder, specs
mk_state() {  # mk_state <dir> [nocfg]: sets ROOT SH REPO HP WTR
  ROOT="$1"; SH="$1/sh"; REPO="$1/repo"; HP="$SH/projects/shop"; WTR="$HP/wt"
  mkdir -p "$REPO" "$SH" "$1/other"
  cp -r "$REPO_TEMPLATE/." "$REPO/"; cp -r "$REPO_TEMPLATE/." "$1/other/"
  if [ "${2:-}" != nocfg ]; then
    mkdir -p "$REPO/.shipfloor"; cp "$FACTORY_DIR/test/fixture/factory.yml" "$REPO/.shipfloor/factory.yml"
    git -C "$REPO" add -A; git -C "$REPO" commit -qm config
  fi
  git -C "$REPO" worktree add -q --detach "$HP/control"
  printf 'shop\t%s\t%s\n' "$REPO" "$WTR" > "$SH/registry.tsv"
  git -C "$REPO" worktree add -q -b feat/7-demo "$WTR/7"
  git -C "$REPO" worktree add -q -b other "$WTR/9"
  git -C "$REPO" worktree add -q -b feat/10-nospec "$WTR/10"
  local specs="docs/superpowers/specs"
  mkdir -p "$WTR/7/$specs" "$WTR/9/$specs"
  printf '# Demo\n\n**Weight:** heavy\n\n## Product\n' > "$WTR/7/$specs/2026-01-01-demo-design.md"
  printf '# Other\n\n**Weight:** light\n\n## Product\n' > "$WTR/9/$specs/2026-01-01-demo-design.md"
  # tmp/: 7 is Done (stale), 8 is Coding, 9 is off the board (stale), 10 has a lock; strays: old and new
  mkdir -p "$HP/tmp/7" "$HP/tmp/8" "$HP/tmp/9" "$HP/tmp/10" "$HP/locks"
  git -C "$REPO" worktree add -q --detach "$HP/tmp/7/wt"
  printf '7\tDone\n8\tCoding\n10\tCoding\n' > "$HP/board.tsv"; : > "$HP/locks/dev-10.lock"
  echo x > "$HP/tmp/stray-12.log"; touch -d '10 days ago' "$HP/tmp/stray-12.log"
  echo x > "$HP/tmp/new-13.log"
  echo x > "$HP/tmp/old-8.log"; touch -d '10 days ago' "$HP/tmp/old-8.log"
  echo x > "$HP/tmp/old-99.log"; touch -d '10 days ago' "$HP/tmp/old-99.log"
  echo x > "$HP/tmp/old-7.log"; touch -d '10 days ago' "$HP/tmp/old-7.log"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$HP/factory.yml"
}

run_side() {  # run_side <cwd> <op args...>: sets OUT, ERR (paths relative to ROOT), RC
  local cwd="$1"; shift
  local envs=(SHIPFLOOR_HOME="$SH" PARITY_SCRIPTS="$FACTORY_DIR")
  if [ "$1" != resolve ]; then
    envs+=(FACTORY_PROJECT=shop FACTORY_REPO="$REPO" FACTORY_MAIN=main FACTORY_HOME="$HP" FACTORY_WT_ROOT="$WTR" FACTORY_CONFIG="$HP/factory.yml")
  fi
  local clear=(-u FACTORY_CONFIG -u FACTORY_HOME -u FACTORY_REPO -u FACTORY_PROJECT -u FACTORY_WT_ROOT -u FACTORY_MAIN)
  [ "$1" = resolve ] || clear=()
  OUT="$(cd "$cwd" && env "${clear[@]}" "${envs[@]}" "$FACTORY_PYTHON" -I -B "$T/drv.py" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
  OUT="${OUT//$ROOT/<R>}"; ERR="${ERR//$ROOT/<R>}"
}

op() {  # op <label> <nocfg|cfg> <cwd: repo|wt7|other> <op args...>: the operation on a fresh state; PAR_OUT, PAR_PERR
  local label="$1" cfg="$2" where="$3"; shift 3
  local cwd
  N=$((N+1)); mk_state "$T/p$N" "$cfg"; case "$where" in repo) cwd="$ROOT/repo" ;; wt7) cwd="$WTR/7" ;; other) cwd="$ROOT/other" ;; esac
  [ "$1" = snapshot ] && rm -f "$HP/factory.yml"
  run_side "$cwd" "$@"
  # the package does not load: nothing below can check anything, and one line says so
  if [ "$RC" -eq 70 ]; then fail "$label: the Python side cannot run: $ERR"; exit 1; fi
  PAR_PERR="$ERR"; PAR_OUT="$OUT"
}
is() {  # is <label> <want>: PAR_OUT is exactly that
  [ "$PAR_OUT" = "$2" ] && pass "$1" || fail "$1: [$PAR_OUT], want [$2]"
}

# ---- AC-4: resolve from a worktree
op "AC-4 resolve from a card worktree" cfg wt7 resolve
RESOLVED="rc=0
PROJECT=shop
REPO=<R>/repo
MAIN=main
HOME=<R>/sh/projects/shop
WT_ROOT=<R>/sh/projects/shop/wt
CONFIG=<R>/sh/projects/shop/factory.yml"
is "AC-4 resolve from a card worktree: the registered project, its home, worktrees and config" "$RESOLVED"
op "AC-4 resolve from the repository" cfg repo resolve
is "AC-4 resolve from the repository: the same project" "$RESOLVED"

# ---- AC-4: the resolve failure message
op "AC-4 resolve outside a registered project" cfg other resolve
[ "$PAR_PERR" = "shipfloor: <R>/other is not in a registered project (shipfloor add <repo>)" ] && pass "AC-4 resolve failure: the message names the directory" || fail "AC-4 resolve failure says: [$PAR_PERR]"
case "$PAR_OUT" in "rc=1") pass "AC-4 resolve failure: rc=1, nothing exported" ;; *) fail "AC-4 resolve failure: [$PAR_OUT]" ;; esac

# ---- AC-4: snapshot
op "AC-4 snapshot of the committed config" cfg repo snapshot
is "AC-4 snapshot of the committed config: rc=0" "rc=0"
cmp -s "$HP/factory.yml" "$FACTORY_DIR/test/fixture/factory.yml" && pass "AC-4 snapshot writes the committed config to the project's home" || fail "AC-4 snapshot: $HP/factory.yml is not the committed config"
op "AC-4 snapshot with no committed config" nocfg repo snapshot
is "AC-4 snapshot with no committed config: rc=1" "rc=1"

# ---- AC-4: the three tmp helpers
op "AC-4 stale_tmp" cfg repo stale
[ "$PAR_OUT" = "$(printf '7\n9')" ] && pass "AC-4 stale_tmp names the cards 7 (Done) and 9 (off the board), not 8 (Coding) or 10 (locked)" || fail "AC-4 stale_tmp is [$PAR_OUT], want 7 and 9"
op "AC-4 clean_tmp" cfg repo clean 7
[ -d "$HP/tmp/7" ] && fail "AC-4 clean_tmp left tmp/7" || pass "AC-4 clean_tmp removes tmp/7"
[ "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" = 5 ] && pass "AC-4 clean_tmp removes the worktree it left under tmp/7" || fail "AC-4 clean_tmp left its worktree registered"
op "AC-4 sweep_tmp" cfg repo sweep
want_sweep="$(printf 'tmp/7\ntmp/9\ntmp/old-7.log\ntmp/old-99.log\ntmp/stray-12.log' | sort)"
[ "$PAR_OUT" = "$want_sweep" ] && pass "AC-4 sweep_tmp prints each thing it removed" || fail "AC-4 sweep_tmp printed [$PAR_OUT], want [$want_sweep]"

# ---- AC-4: the card's spec and weight
op "AC-4 card_spec of a card with a spec" cfg repo card_spec 7
case "$PAR_OUT" in *7/docs/superpowers/specs/2026-01-01-demo-design.md) pass "AC-4 card_spec finds the spec in the card's worktree" ;; *) fail "AC-4 card_spec found [$PAR_OUT]" ;; esac
op "AC-4 card_spec of a card with no worktree" cfg repo card_spec 8
[ -z "$PAR_OUT" ] && pass "AC-4 card_spec: nothing without a worktree" || fail "AC-4 card_spec without a worktree found [$PAR_OUT]"
op "AC-4 card_spec of a card on another branch" cfg repo card_spec 9
is "AC-4 card_spec: nothing for a worktree on another card's branch" ""
op "AC-4 card_spec of a card with no spec file" cfg repo card_spec 10
is "AC-4 card_spec: nothing without a spec file" ""
op "AC-4 card_weight of a card with a heavy spec" cfg repo card_weight 7
[ "$PAR_OUT" = heavy ] && pass "AC-4 card_weight reads heavy" || fail "AC-4 card_weight 7 is [$PAR_OUT], want heavy"
op "AC-4 card_weight of a card with no worktree" cfg repo card_weight 8
[ "$PAR_OUT" = standard ] && pass "AC-4 card_weight: standard without a worktree" || fail "AC-4 card_weight 8 is [$PAR_OUT], want standard"
op "AC-4 card_weight of a card with no spec file" cfg repo card_weight 10
is "AC-4 card_weight: standard without a spec file" standard

# spec_weight: none, two lines, unknown value, CRLF, ...
W="$T/weights"; mkdir -p "$W"
printf '# T\n\n**Issue:** #1\n\n## Product\n' > "$W/none.md"
printf '# T\n\n**Weight:** heavy\n\n## Product\n' > "$W/heavy.md"
printf '# T\n\n**Weight:** `light`\n\n## Product\n' > "$W/ticks.md"
printf '# T\n\n**Weight:**    standard  \n\n## Product\n' > "$W/spaces.md"
printf '# T\n\n**Weight:** light\n**Weight:** heavy\n\n## Product\n' > "$W/two.md"
printf '# T\n\n**Weight:** gigantic\n\n## Product\n' > "$W/unknown.md"
printf '# T\r\n\r\n**Weight:** heavy\r\n\r\n## Product\r\n' > "$W/crlf.md"
printf '# T\r\n\r\n**Weight:** `light`\r\n\r\n## Product\r\n' > "$W/crlf-ticks.md"
printf '# T\n\n## Product\n\n**Weight:** heavy\n' > "$W/after-section.md"
printf '# T\n\n**Weight:** Heavy\n' > "$W/capital.md"
for pair in none:standard heavy:heavy ticks:light spaces:standard two:standard unknown:standard crlf:heavy crlf-ticks:light after-section:standard capital:standard missing:standard; do
  f="${pair%%:*}"; w="${pair##*:}"
  run_side "$ROOT/repo" spec_weight "$W/$f.md"
  [ "$OUT" = "$w" ] && pass "AC-4 spec_weight $f is $w" || fail "AC-4 spec_weight $f is [$OUT], want $w"
done

# ---- AC-6: say
cat > "$T/say-lines.txt" <<'EOF'
acceptance tests changed after the QA commit (beyond what merges from main brought):
acceptance tests changed after the QA commit
the owner can review these files and record them as they stand: shipfloor accept
QA commit abc1234 has no files
the last commit is not a QA commit
the acceptance tests of #162 were already amended 2 times; the owner decides now
the amendment touches files that are not tests:
the amendment removes 3 assertion lines and adds 1; an amended test may check differently, not less
qa-amend: ok, 4 assertion lines replaced by 5
build: reused the pass on abc123 recorded 2026-10-14; nothing ran
green: reused the pass on def456 recorded today; nothing ran
build: factory build failed
gate: bad revision
gate: unknown layer
red: selector required
green: selector required
green: acceptance tests fail:
red: tests passed before implementation; they prove nothing
red: no assertion failure found in test output
migration: V3__x.sql already exists on the base; applied migrations are immutable (add a new file)
migration: base abc is not an ancestor of HEAD
scope: factory touched files outside its area:
scope: role required
test-plan: spec 'docs/x.md' not found
version 2 is used by V2__a.sql
Back to Coding: the gates failed
Factory deploy stopped: CI failed
Deployed: merge 12 min from the start of this deploy run.
Production deploy failed: timeout
Revert PR: https://example.test/pull/9
3 files conflict with main (limit 2)
5 hunks conflict with main (limit 4)
merge failed: conflicts
gates failed: build
CI failed on the PR after merging main
PR #162 comes from a fork; the factory deploys only its own branches
expected one open PR for #7, found: 2
push of feat/7-x failed (the branch moved?)
CI on abc1234 failed (run 99: timed_out); running its failed jobs once more
deployment to 'production' ended 'failure'
PR #5 was already merged as abc123; checking production
cannot read #12 comments
#7 is in 'Coding', not Ready for Prod
fix round 1 of 2: build
small fix (2 files, 30 lines): it ships with the approved head
dispatch: #162 runs on opus, one model up after sonnet failed gate green
outside working hours; runs start again at 08:30
removed a stale index.lock (older than 10 min): /tmp/x
Claude usage limit hit recently; waiting
dispatch: board read failed
Factory report
staged-head: abc123
== start
nothing to translate here
a line with ação and çã accents, and a trailing space
EOF
op "AC-6 say pt-BR on every fixture line" cfg repo say pt-BR "$T/say-lines.txt"
n_in="$(grep -c . "$T/say-lines.txt")"; n_out="$(printf '%s\n' "$PAR_OUT" | grep -c .)"
[ "$n_in" = "$n_out" ] && pass "AC-6 say pt-BR: one output line per fixture line ($n_in)" || fail "AC-6 say pt-BR: $n_in lines in, $n_out out"
case "$PAR_OUT" in *"os testes de aceitação mudaram depois do commit do QA"*) pass "AC-6 say pt-BR translates a catalog line" ;; *) fail "AC-6 say pt-BR left the catalog line in English: [$PAR_OUT]" ;; esac

for lang in en xx; do
  op "AC-6 say $lang (no catalog)" cfg repo say "$lang" "$T/say-lines.txt"
  expect="$(cat "$T/say-lines.txt")"
  [ "$PAR_OUT" = "${expect}" ] && pass "AC-6 say $lang: the text passes through unchanged" || fail "AC-6 say $lang: the text changed: [$PAR_OUT]"
done

finish
