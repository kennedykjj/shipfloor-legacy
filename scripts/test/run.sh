#!/usr/bin/env bash
# Runs every *.test.sh in this folder in parallel (TEST_JOBS, default: CPU count) and prints each
# file's output in order; exits non-zero if any fails. Every test file works in its own temp dirs.
# usage: run.sh [file.test.sh ...]
cd "$(dirname "$0")" || exit 1
jobs="${TEST_JOBS:-$(nproc 2>/dev/null || echo 4)}"
out="$(mktemp -d)"; start="$(date +%s)"
if [ $# -gt 0 ]; then files=("$@"); else
  # the slowest files first, so the run takes about as long as the slowest one
  mapfile -t files < <(ls -S *.test.sh | grep '^deploy-'; ls *.test.sh | grep -v '^deploy-')
fi
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
