#!/usr/bin/env bash
# The cycle's Claude-usage-limit check reads only the run logs, projects/<p>/logs/*.log: a test suite that runs inside
# a card's TMPDIR (projects/<p>/tmp/<n>/tmp, #168) writes fake factory logs that say "hit your session limit", and the
# old recursive scan paused the whole factory on them.
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)" || exit 1
check() { "$FACTORY_PYTHON" -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from shipfloor_core import cycle; sys.exit(0 if cycle.usage_limited(sys.argv[2]) else 1)' "$FACTORY_DIR" "$1"; }
h="$T/home"; mkdir -p "$h/projects/shop/logs" "$h/projects/shop/tmp/5/tmp/x/projects/blog/logs" "$h/projects/shop/tmp/5/tmp/y/logs"
printf '== start /sf:develop 5\nYou have hit your session limit\n' > "$h/projects/shop/tmp/5/tmp/x/projects/blog/logs/x-5-develop.log"
cp "$h/projects/shop/tmp/5/tmp/x/projects/blog/logs/x-5-develop.log" "$h/projects/shop/tmp/5/tmp/y/logs/x-5-develop.log"
printf '== start /sf:develop 7\nall fine\n== end\n' > "$h/projects/shop/logs/2026-10-14-7-develop.log"
check "$h" && fail "a fake log under a card's tmp/ paused the factory" || pass "logs under projects/<p>/tmp/ are not run logs"
printf '== start /sf:develop 8\nYou have hit your session limit\n' > "$h/projects/shop/logs/2026-10-14-8-develop.log"
check "$h" && pass "a run log that hit the limit pauses the factory" || fail "a run log that hit the limit was missed"
printf '== start /sf:develop 8\nYou have hit your session limit\n== end\n== start /sf:develop 8\nok\n' > "$h/projects/shop/logs/2026-10-14-8-develop.log"
check "$h" && fail "an older run's hit still pauses" || pass "only the log's last run counts"
finish
