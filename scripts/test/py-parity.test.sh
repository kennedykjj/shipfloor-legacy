#!/usr/bin/env bash
# Parity (#162): shipfloor_core.project / shipfloor_core.text against lib/project.sh on the same fixtures.
# Each case builds two identical states (one for Bash, one for Python), runs the operation on each and compares
# what it printed (paths made relative to the state) and what it left on disk.
#   AC-4  resolve from a worktree, the resolve failure message, snapshot, the three tmp helpers, weight
#   AC-6  say('pt-BR', line) equals shipfloor_say pt-BR on every line; no catalog: the text passes through unchanged
source "$(dirname "$0")/lib.sh"
LIBP="$FACTORY_DIR/lib/project.sh"
T="$(mktemp -d)"; N=0
export GIT_TERMINAL_PROMPT=0

# ---- the Bash side: one operation, printed in the form the Python driver prints
cat > "$T/bash-op.sh" <<'EOF'
source "$LIBP"
op="$1"; shift
case "$op" in
  resolve) shipfloor_resolve; rc=$?; echo "rc=$rc"
           if [ "$rc" = 0 ]; then for v in PROJECT REPO MAIN HOME WT_ROOT CONFIG; do n="FACTORY_$v"; echo "$v=${!n:-}"; done; fi ;;
  snapshot) shipfloor_snapshot; echo "rc=$?" ;;
  stale) shipfloor_stale_tmp | sort ;;
  clean) shipfloor_clean_tmp "$1" ;;
  sweep) shipfloor_sweep_tmp | sort ;;
  spec_weight) shipfloor_spec_weight "$1" ;;
  card_spec) shipfloor_card_spec "$1" ;;
  card_weight) shipfloor_card_weight "$1" ;;
  say) while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l" | shipfloor_say "$1"; done < "$2" ;;
esac
EOF

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

state_text() {  # what the operation left on disk, relative to the state
  { (cd "$HP" 2>/dev/null && find tmp -mindepth 1 | sort); git -C "$REPO" worktree list | wc -l | tr -d ' '
    [ -f "$HP/factory.yml" ] && cat "$HP/factory.yml"; } 2>/dev/null
}

run_side() {  # run_side bash|py <cwd> <op args...>: sets OUT, ERR (paths relative to ROOT)
  local side="$1" cwd="$2"; shift 2
  local envs=(SHIPFLOOR_HOME="$SH" LIBP="$LIBP" PARITY_SCRIPTS="$FACTORY_DIR")
  if [ "$1" != resolve ]; then
    envs+=(FACTORY_PROJECT=shop FACTORY_REPO="$REPO" FACTORY_MAIN=main FACTORY_HOME="$HP" FACTORY_WT_ROOT="$WTR" FACTORY_CONFIG="$HP/factory.yml")
  fi
  local clear=(-u FACTORY_CONFIG -u FACTORY_HOME -u FACTORY_REPO -u FACTORY_PROJECT -u FACTORY_WT_ROOT -u FACTORY_MAIN)
  [ "$1" = resolve ] || clear=()
  if [ "$side" = bash ]; then
    OUT="$(cd "$cwd" && env "${clear[@]}" "${envs[@]}" bash "$T/bash-op.sh" "$@" 2>"$T/err")"; RC=$?
  else
    OUT="$(cd "$cwd" && env "${clear[@]}" "${envs[@]}" "$FACTORY_PYTHON" -I -B "$T/drv.py" "$@" 2>"$T/err")"; RC=$?
  fi
  ERR="$(cat "$T/err")"
  OUT="${OUT//$ROOT/<R>}"; ERR="${ERR//$ROOT/<R>}"
}

parity() {  # parity <label> <nocfg|cfg> <cwd: repo|wt7|other> <op args...>: both sides print the same; and leave the same on disk
  local label="$1" cfg="$2" where="$3"; shift 3
  local cwd_rel b_out b_err b_disk p_out p_err p_disk p_rc
  N=$((N+1)); mk_state "$T/b$N" "$cfg"; case "$where" in repo) cwd_rel="$ROOT/repo" ;; wt7) cwd_rel="$WTR/7" ;; other) cwd_rel="$ROOT/other" ;; esac
  [ "$1" = snapshot ] && rm -f "$HP/factory.yml"
  run_side bash "$cwd_rel" "$@"; b_out="$OUT"; b_err="$ERR"; b_disk="$(state_text)"; b_disk="${b_disk//$ROOT/<R>}"
  mk_state "$T/p$N" "$cfg"; case "$where" in repo) cwd_rel="$ROOT/repo" ;; wt7) cwd_rel="$WTR/7" ;; other) cwd_rel="$ROOT/other" ;; esac
  [ "$1" = snapshot ] && rm -f "$HP/factory.yml"
  run_side py "$cwd_rel" "$@"; p_out="$OUT"; p_err="$ERR"; p_rc=$RC; p_disk="$(state_text)"; p_disk="${p_disk//$ROOT/<R>}"
  # the package does not load: nothing below can compare anything, and one line says so
  if [ "$p_rc" -eq 70 ]; then fail "$label: the Python side cannot run: $p_err"; exit 1; fi
  if [ "$p_out" = "$b_out" ]; then pass "$label: same output"; else fail "$label: output differs. bash: [$b_out] python: [$p_out] ($p_err)"; fi
  if [ "$p_disk" = "$b_disk" ]; then pass "$label: same state left on disk"; else fail "$label: disk differs. bash: [$b_disk] python: [$p_disk]"; fi
  PAR_BERR="$b_err"; PAR_PERR="$p_err"; PAR_OUT="$p_out"
}

# ---- AC-4: resolve from a worktree
parity "AC-4 resolve from a card worktree" cfg wt7 resolve
case "$PAR_OUT" in "rc=0"*"PROJECT=shop"*) pass "AC-4 resolve from a card worktree: the project is shop" ;; *) fail "AC-4 resolve from a card worktree: not resolved: [$PAR_OUT]" ;; esac
parity "AC-4 resolve from the repository" cfg repo resolve

# ---- AC-4: the resolve failure message
parity "AC-4 resolve outside a registered project" cfg other resolve
[ -n "$PAR_BERR" ] && pass "AC-4 resolve failure: bash says '$PAR_BERR'" || fail "AC-4 resolve failure: bash printed no message"
while IFS= read -r l; do
  case "$PAR_PERR" in *"$l"*) pass "AC-4 resolve failure: python says '$l'" ;; *) fail "AC-4 resolve failure: python lacks '$l'; it says: [$PAR_PERR]" ;; esac
done <<< "$PAR_BERR"
case "$PAR_OUT" in "rc=1") pass "AC-4 resolve failure: rc=1, nothing exported" ;; *) fail "AC-4 resolve failure: [$PAR_OUT]" ;; esac

# ---- AC-4: snapshot
parity "AC-4 snapshot of the committed config" cfg repo snapshot
parity "AC-4 snapshot with no committed config" nocfg repo snapshot

# ---- AC-4: the three tmp helpers
parity "AC-4 stale_tmp" cfg repo stale
[ "$PAR_OUT" = "$(printf '7\n9')" ] && pass "AC-4 stale_tmp names the cards 7 (Done) and 9 (off the board), not 8 (Coding) or 10 (locked)" || fail "AC-4 stale_tmp is [$PAR_OUT], want 7 and 9"
parity "AC-4 clean_tmp" cfg repo clean 7
[ -d "$HP/tmp/7" ] && fail "AC-4 clean_tmp left tmp/7" || pass "AC-4 clean_tmp removes tmp/7"
[ "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" = 5 ] && pass "AC-4 clean_tmp removes the worktree it left under tmp/7" || fail "AC-4 clean_tmp left its worktree registered"
parity "AC-4 sweep_tmp" cfg repo sweep
want_sweep="$(printf 'tmp/7\ntmp/9\ntmp/old-7.log\ntmp/old-99.log\ntmp/stray-12.log' | sort)"
[ "$PAR_OUT" = "$want_sweep" ] && pass "AC-4 sweep_tmp prints each thing it removed" || fail "AC-4 sweep_tmp printed [$PAR_OUT], want [$want_sweep]"

# ---- AC-4: the card's spec and weight
parity "AC-4 card_spec of a card with a spec" cfg repo card_spec 7
case "$PAR_OUT" in *7/docs/superpowers/specs/2026-01-01-demo-design.md) pass "AC-4 card_spec finds the spec in the card's worktree" ;; *) fail "AC-4 card_spec found [$PAR_OUT]" ;; esac
parity "AC-4 card_spec of a card with no worktree" cfg repo card_spec 8
[ -z "$PAR_OUT" ] && pass "AC-4 card_spec: nothing without a worktree" || fail "AC-4 card_spec without a worktree found [$PAR_OUT]"
parity "AC-4 card_spec of a card on another branch" cfg repo card_spec 9
parity "AC-4 card_spec of a card with no spec file" cfg repo card_spec 10
parity "AC-4 card_weight of a card with a heavy spec" cfg repo card_weight 7
[ "$PAR_OUT" = heavy ] && pass "AC-4 card_weight reads heavy" || fail "AC-4 card_weight 7 is [$PAR_OUT], want heavy"
parity "AC-4 card_weight of a card with no worktree" cfg repo card_weight 8
[ "$PAR_OUT" = standard ] && pass "AC-4 card_weight: standard without a worktree" || fail "AC-4 card_weight 8 is [$PAR_OUT], want standard"
parity "AC-4 card_weight of a card with no spec file" cfg repo card_weight 10

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
for f in none heavy ticks spaces two unknown crlf crlf-ticks after-section capital missing; do
  parity "AC-4 spec_weight $f" cfg repo spec_weight "$W/$f.md"
done
for pair in none:standard heavy:heavy ticks:light two:standard unknown:standard crlf:heavy crlf-ticks:light after-section:standard missing:standard; do
  f="${pair%%:*}"; w="${pair##*:}"
  run_side py "$ROOT/repo" spec_weight "$W/$f.md"
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
parity "AC-6 say pt-BR on every fixture line" cfg repo say pt-BR "$T/say-lines.txt"
n_in="$(grep -c . "$T/say-lines.txt")"; n_out="$(printf '%s\n' "$PAR_OUT" | grep -c .)"
[ "$n_in" = "$n_out" ] && pass "AC-6 say pt-BR: one output line per fixture line ($n_in)" || fail "AC-6 say pt-BR: $n_in lines in, $n_out out"
case "$PAR_OUT" in *"os testes de aceitação mudaram depois do commit do QA"*) pass "AC-6 say pt-BR translates a catalog line" ;; *) fail "AC-6 say pt-BR left the catalog line in English: [$PAR_OUT]" ;; esac

for lang in en xx; do
  parity "AC-6 say $lang (no catalog)" cfg repo say "$lang" "$T/say-lines.txt"
  expect="$(cat "$T/say-lines.txt")"
  [ "$PAR_OUT" = "${expect}" ] && pass "AC-6 say $lang: the text passes through unchanged" || fail "AC-6 say $lang: the text changed: [$PAR_OUT]"
done

finish
