#!/usr/bin/env bash
# Runs every *.test.sh in this folder in parallel (TEST_JOBS, default: half the CPUs) and prints each
# file's output in order; exits non-zero if any fails. Every test file works in its own temp dirs, all under
# one TMPDIR that goes when the run ends, killed or not.
# usage: run.sh [file.test.sh ...] | run.sh --changed [base]   (SUITE=<name> runs one suite, SHARD=i/N one of N shares)
#   --changed  only the tests tied to what changed against <base> (default origin/main), committed or
#              not: for the edit-test loop. Run the whole suite before a push.
cd "$(dirname "$0")" || exit 1
if [ "${1:-}" = --changed ]; then
  top="$(git rev-parse --show-toplevel)" || exit 1; here="$(git rev-parse --show-prefix)"; here="${here%/}"
  changed="$({ git -C "$top" diff --name-only "${2:-origin/main}"...HEAD; git -C "$top" diff --name-only HEAD
               git -C "$top" ls-files --others --exclude-standard; } | sort -u)"
  set --
  # a shared helper or fixture can change any test: run them all
  if ! printf '%s
' "$changed" | grep -qE "^$here/(lib\.sh|deploy-lib\.sh|run\.sh|fixture/|fake-)|/lib/"; then
    for t in *.test.sh; do
      for f in $changed; do
        if [ "$f" = "$here/$t" ] || grep -qF -- "${f##*/}" "$t"; then set -- "$@" "$t"; break; fi
      done
    done
    [ $# -gt 0 ] || { echo "== nothing to run: no test is tied to what changed against ${2:-origin/main}"; exit 0; }
  fi
fi
# half the CPUs: these tests are process starts, and one job per CPU made the same suite take twice as long (652s vs 313s on 16)
jobs="${TEST_JOBS:-$(( ($(nproc 2>/dev/null || echo 8) + 1) / 2 ))}"
out="$(mktemp -d)"; start="$(date +%s)"
# The tests never remove their mktemp dirs: a full suite left ~3,000 of them, git repos included, and parallel
# gates filled a tmpfs /tmp's inodes within an hour. Here they all land under $out, removed on any exit.
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/tmp"; export TMPDIR="$out/tmp"
if [ $# -gt 0 ]; then files=("$@"); else
  # the slowest files first, so the run takes about as long as the slowest one
  mapfile -t files < <(ls -S *.test.sh | grep '^deploy-'; ls *.test.sh | grep -v '^deploy-')
fi
# SUITE=unit|integration|end-to-end (CI runs each on its own runner): only the files whose second line is
# "# suite: <name>". unit: in-process Python modules (py_suite); integration: real processes, git and the fakes;
# end-to-end: the whole factory (chaos, the demo stack, a browser). hygiene.test.sh checks every file names one.
if [ -n "${SUITE:-}" ]; then
  case "$SUITE" in unit|integration|end-to-end) ;; *) echo "run.sh: SUITE must be unit, integration or end-to-end" >&2; exit 2 ;; esac
  picked=(); for f in "${files[@]}"; do [ "$(sed -n 2p "$f")" = "# suite: $SUITE" ] && picked+=("$f"); done
  [ ${#picked[@]} -gt 0 ] || { echo "== nothing to run: no test in suite $SUITE"; exit 0; }
  files=("${picked[@]}")
fi
unset SUITE
# SHARD=i/N (CI splits the suite over N runners): this run takes every Nth file, counted from i, of the files by
# size, largest first, so each shard gets a fair share of the long ones; together the N shards run every file once
if [ -n "${SHARD:-}" ]; then
  si="${SHARD%/*}" sn="${SHARD#*/}"
  [[ "$si" =~ ^[0-9]+$ && "$sn" =~ ^[0-9]+$ && "$si" -ge 1 && "$si" -le "$sn" ]] || { echo "run.sh: SHARD must be i/N with 1 <= i <= N" >&2; exit 2; }
  mapfile -t bysize < <(ls -S "${files[@]}")
  files=(); for k in "${!bysize[@]}"; do [ $(( k % sn + 1 )) = "$si" ] && files+=("${bysize[$k]}"); done
fi
unset SHARD  # a test that runs run.sh itself (test-infra) must see the whole folder
# the deploy tests share one base repo: built here once, not once per file
case " ${files[*]}" in *" deploy-"*) DEPLOY_BASE="$(source ./deploy-lib.sh; echo "$BASE")"; export DEPLOY_BASE ;; esac
printf '%s\n' "${files[@]}" | xargs -P "$jobs" -I{} bash -c \
  's=$(date +%s); bash "$1" > "$2/$1.out" 2>&1; echo "$? $(( $(date +%s) - s ))" > "$2/$1.rc"' _ {} "$out"
status=0; failed=()
for t in $(printf '%s\n' "${files[@]}" | sort); do
  read -r rc secs < "$out/$t.rc"
  echo "== $t (${secs}s)"; cat "$out/$t.out"
  [ "$rc" = 0 ] || { status=1; failed+=("$t"); }
done
oks="$(cat "$out"/*.out | grep -c '^  ok')"; fails="$(cat "$out"/*.out | grep -c '^  FAIL')"
echo "== ${#files[@]} files · $oks ok · $fails FAIL · $(( $(date +%s) - start ))s with $jobs jobs${failed:+ · failed: ${failed[*]}}"
rm -rf "$out"
exit $status
