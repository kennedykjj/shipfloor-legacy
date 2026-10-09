#!/usr/bin/env bash
# Runs every *.test.sh in this folder; exits non-zero if any fails.
cd "$(dirname "$0")" || exit 1
status=0
for t in *.test.sh; do
  echo "== $t"
  bash "$t" || status=1
done
exit $status
