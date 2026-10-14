#!/usr/bin/env bash
# #167: deploy.sh ported to Python (shipfloor_core/deploy.py, run through sf.py) behaves exactly as the Bash one did.
#   AC-1..AC-7  every scenario of the deploy-*.test.sh suite is replayed twice: against the Bash deploy.sh kept as
#               test/fixtures/deploy-bash.sh and against today's deploy.sh. Each deploy.sh run leaves a record (exit
#               code, stdout, stderr, the fake gh's full call log in order, the comments, labels and board status,
#               the remote's refs, the hand-over files, the lock and the card's worktree); the two records must match,
#               run by run, once the case's temp paths and commit shas (numbered per run) are written out.
#   AC-8        deploy.sh is the thin wrapper of sf.py deploy; the suite passes, unedited, against both.
# The replay runs in two plain copies of scripts/ where deploy.sh is a recorder in front of the implementation.
source "$(dirname "$0")/lib.sh"
here="$FACTORY_DIR/test"

# --- AC-8: the port is in place --------------------------------------------------------------------------------
w="$FACTORY_DIR/deploy.sh"; code="$(grep -vE '^[[:space:]]*(#|$)' "$w")"
[ "$(printf '%s\n' "$code" | wc -l)" -le 5 ] && pass "AC-8 deploy.sh is a few lines" || fail "AC-8 deploy.sh still holds the logic ($(printf '%s\n' "$code" | wc -l) lines of code)"
case "$code" in *'lib/py.sh'*) pass "AC-8 deploy.sh sources lib/py.sh" ;; *) fail "AC-8 deploy.sh does not source lib/py.sh" ;; esac
case "$code" in *deploy*) pass "AC-8 deploy.sh runs the deploy command" ;; *) fail "AC-8 deploy.sh never names the deploy command" ;; esac
if printf '%s\n' "$code" | grep -qE '(^|[[:space:];])(if|case|for|while|until)[[:space:]]|git |gh |python|shipfloor_resolve|lib/project\.sh'; then
  fail "AC-8 deploy.sh has control flow, git, gh or python in it"
else pass "AC-8 deploy.sh has no control flow, git, gh or python"; fi
[ -f "$FACTORY_DIR/shipfloor_core/deploy.py" ] && pass "AC-8 shipfloor_core/deploy.py exists" || fail "AC-8 no shipfloor_core/deploy.py"
out="$("$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" deploy x 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && [ "$out" = "usage: deploy.sh <n> [--refresh | --continue]" ] && pass "AC-8 sf.py deploy is registered (usage, exit 2)" \
  || fail "AC-8 sf.py deploy x: exit $rc, stderr: $out"
[ -f "$here/fixtures/deploy-bash.sh" ] && pass "AC-8 the Bash deploy.sh is kept as a fixture" || fail "AC-8 no test/fixtures/deploy-bash.sh"
grep -q 'shipfloor_cfg values project.repo project.main' "$here/fixtures/deploy-bash.sh" && pass "AC-8 the fixture is the Bash implementation" || fail "AC-8 the fixture is not the Bash deploy.sh"

# --- the replay ------------------------------------------------------------------------------------------------
# one base repo for both sides (run.sh builds it for the suite), so the shas it holds are the same on both
[ -d "${DEPLOY_BASE:-}/repo" ] || DEPLOY_BASE="$(source "$here/deploy-lib.sh"; echo "$BASE")"
export DEPLOY_BASE
work="$(mktemp -d)"
copy_side() {  # copy_side <side> <implementation, relative to scripts/>: a copy of scripts/ whose deploy.sh records each run
  local s="$work/$1/scripts"; mkdir -p "$work/$1"; cp -r "$FACTORY_DIR" "$s"
  find "$s" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  cp "$FACTORY_DIR/deploy.sh" "$s/deploy-port.sh"
  cat > "$s/deploy.sh" <<EOF
#!/usr/bin/env bash
# recorder (deploy-differential.test.sh): runs the implementation, passes its output on, then appends a record
o="\$(mktemp)"; e="\$(mktemp)"
bash "$s/$2" "\$@" >"\$o" 2>"\$e"; rc=\$?
cat "\$o"; cat "\$e" >&2
if [ -n "\${DIFF_LOG:-}" ]; then
  {
    printf '=== deploy.sh %s\n' "\$*"
    printf 'S=%s\n' "$s"; [ -n "\${FG:-}" ] && printf 'T=%s\n' "\${FG%/fg}"
    echo "exit \$rc"; echo "--- stdout"; cat "\$o"; echo "--- stderr"; cat "\$e"
    if [ -n "\${FG:-}" ] && [ -d "\$FG" ]; then
      for f in calls comments labels status merged; do echo "--- \$f"; cat "\$FG/\$f" 2>/dev/null; done
      echo "--- remote"; r="\$(cat "\$FG/remote" 2>/dev/null)"
      [ -n "\$r" ] && git --git-dir="\$r" for-each-ref --format='%(refname)' | while read -r ref; do
        printf '%s %s %s\n' "\$ref" "\$(git --git-dir="\$r" log -1 --format='%H %T %P %s' "\$ref")" "\$(git --git-dir="\$r" rev-list --count "\$ref")"
      done
    fi
    n="\${1:-}"
    if [ -n "\${FACTORY_HOME:-}" ] && [ -n "\$n" ]; then
      echo "--- tmp"; for f in fix.round fix.parent resolve.parents resolve.files fix.findings; do
        [ -e "\$FACTORY_HOME/tmp/\$n/\$f" ] && { echo "[\$f]"; cat "\$FACTORY_HOME/tmp/\$n/\$f"; }
      done
      [ -e "\$FACTORY_HOME/locks/deploysh-\$n.lock" ] && echo "lock held"
    fi
    if [ -n "\${FACTORY_WT_ROOT:-}" ] && [ -e "\$FACTORY_WT_ROOT/\$n/.git" ]; then
      echo "--- worktree"; git -C "\$FACTORY_WT_ROOT/\$n" rev-parse HEAD 2>&1; git -C "\$FACTORY_WT_ROOT/\$n" status --porcelain 2>&1
      git -C "\$FACTORY_WT_ROOT/\$n" rev-parse -q --verify MERGE_HEAD 2>&1
    fi
    [ -n "\${FACTORY_WT_ROOT:-}" ] && [ -e "\$FACTORY_WT_ROOT/revert-\$n" ] && echo "revert worktree left"
  } >> "\$DIFF_LOG"
fi
rm -f "\$o" "\$e"; exit \$rc
EOF
  chmod +x "$s/deploy.sh"
}
copy_side bash test/fixtures/deploy-bash.sh
copy_side port deploy-port.sh

mapfile -t files < <(cd "$here" && ls -S deploy-*.test.sh | grep -vx 'deploy-differential.test.sh')
[ "${#files[@]}" -ge 10 ] && pass "replaying ${#files[@]} deploy test files" || fail "only ${#files[@]} deploy test files found"
mkdir -p "$work/logs"
for f in "${files[@]}"; do printf '%s\n%s\n' "bash $f" "port $f"; done | xargs -P "${DIFF_JOBS:-4}" -L 1 bash -c \
  'DIFF_LOG="$1/logs/$2.$3.log" bash "$1/$2/scripts/test/$3" > "$1/logs/$2.$3.out" 2>&1; echo $? > "$1/logs/$2.$3.rc"' _ "$work"

normalize() {  # normalize <log>: the case's paths written out, and each run's shas numbered in order of appearance
  "$FACTORY_PYTHON" -I -c '
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
out = []
for rec in re.split(r"(?m)^(?==== deploy\.sh )", data):
    if not rec:
        continue
    for key, name in (("T", "<case>"), ("S", "<scripts>")):
        m = re.search(r"(?m)^%s=(.*)$" % key, rec)
        if m and m.group(1):
            rec = rec.replace(m.group(1), name)
    rec = re.sub(r"pid [0-9]+", "pid <pid>", rec)  # a busy lock names the pid of the test
    shas = {}
    rec = re.sub(r"\b[0-9a-f]{40}\b", lambda m: shas.setdefault(m.group(0), "<sha%d>" % (len(shas) + 1)), rec)
    out.append(rec)
sys.stdout.write("".join(out))
' "$1"
}

for f in "${files[@]}"; do
  for side in bash port; do
    rc="$(cat "$work/logs/$side.$f.rc" 2>/dev/null)"
    [ "$rc" = 0 ] && pass "$f passes against the $side deploy.sh" || fail "$f against the $side deploy.sh: exit ${rc:-?}
$(grep -E '^  FAIL' "$work/logs/$side.$f.out" | head -20)"
  done
  a="$work/logs/bash.$f.log"; b="$work/logs/port.$f.log"
  runs="$(grep -c '^=== deploy.sh ' "$a" 2>/dev/null)"
  [ "${runs:-0}" -gt 0 ] && pass "$f: $runs deploy.sh runs recorded" || { fail "$f: no deploy.sh run recorded"; continue; }
  d="$(diff <(normalize "$a") <(normalize "$b"))"
  [ -z "$d" ] && pass "$f: the Python deploy.sh matches the Bash one, run by run" || fail "$f: the runs differ (< bash, > port):
$(printf '%s\n' "$d" | head -60)"
done
finish
