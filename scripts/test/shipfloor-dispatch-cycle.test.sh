#!/usr/bin/env bash
# #160 AC-5: shipfloor-dispatch.sh's cycle, pinned as it is today.
#  - an empty or missing registry exits 0 with no health line
#  - SHIPFLOOR_STALE_LOCK_MIN overrides the 10 minutes after which an index.lock is taken for a dead git's
#  - the SKIPPED reason: format of the file and of the reason taken from git's error
#  - the health line (logs/health-<month>.jsonl) is written on PAUSE, on the usage limit and on an overlap
source "$(dirname "$0")/lib.sh"
MD="$FACTORY_DIR/shipfloor-dispatch.sh"
PY="$FACTORY_PYTHON"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3: no '$2' in: ${1:0:500}" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3: found '$2' in: ${1:0:500}" ;; *) pass "$3" ;; esac; }

setup() {  # setup: a new SHIPFLOOR_HOME, with a dispatch stub that notes each project it is run for
  export SHIPFLOOR_HOME="$(mktemp -d)"; tmp="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "$FACTORY_PROJECT" >> "%s/ran"\n' "$tmp" > "$tmp/dispatch"
  chmod +x "$tmp/dispatch"; export SHIPFLOOR_DISPATCH="$tmp/dispatch"; : > "$tmp/ran"
  unset SHIPFLOOR_STALE_LOCK_MIN SHIPFLOOR_LOCK_RETRY_S SHIPFLOOR_CYCLE_STALE_MIN
}
project() {  # project <slug> [config text | -]: a repo with a remote whose main carries .shipfloor/factory.yml ("-": none); R and REMOTE name them
  local slug="$1" cfg="${2:-}"
  REMOTE="$(mktemp -d)"; git init -q --bare "$REMOTE"
  R="$(new_repo)"
  if [ "$cfg" != - ]; then
    mkdir -p "$R/.shipfloor"
    if [ -n "$cfg" ]; then printf '%s\n' "$cfg" > "$R/.shipfloor/factory.yml"
    else sed "s/name: shop/name: $slug/" "$FACTORY_DIR/test/fixture/factory.yml" > "$R/.shipfloor/factory.yml"; fi
    git -C "$R" add -A; git -C "$R" commit -qm cfg
  fi
  git -C "$R" remote add origin "$REMOTE"; git -C "$R" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$R" "$SHIPFLOOR_HOME/projects/$slug/wt" >> "$SHIPFLOOR_HOME/registry.tsv"
}
bump() { sed -i "s/number: [0-9]*/number: $1/" "$R/.shipfloor/factory.yml"; git -C "$R" commit -qam "bump $1"; git -C "$R" push -q origin main; }
health() { cat "$SHIPFLOOR_HOME"/logs/health-*.jsonl 2>/dev/null; }
health_n() { health | grep -c .; }
hfield() { health | tail -n 1 | "$PY" -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" 2>/dev/null | tr -d '\r'; }
ran_n() { grep -c . "$tmp/ran"; }
hcycle() { hfield '"%s %s" % (d["cycle"]["exit"], d["cycle"]["overlap"])'; }  # "<exit> <overlap>" of the last health line

# ---- AC-5: an empty or missing registry exits 0 with no health line
setup
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "AC-5 a missing registry exits 0" test "$rc" = 0
t "AC-5 ... with no health line" test "$(health_n)" = 0
t "AC-5 ... no logs/ written at all" test ! -e "$SHIPFLOOR_HOME/logs"
t "AC-5 ... no dispatch.pid" test ! -e "$SHIPFLOOR_HOME/dispatch.pid"
t "AC-5 ... and it says nothing" test ! -s "$tmp/out"
setup; : > "$SHIPFLOOR_HOME/registry.tsv"
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "AC-5 an empty registry exits 0" test "$rc" = 0
t "AC-5 ... with no health line" test "$(health_n)" = 0
t "AC-5 ... no dispatch.pid" test ! -e "$SHIPFLOOR_HOME/dispatch.pid"
t "AC-5 ... nothing dispatched" test "$(ran_n)" = 0
# contrast: one project in the registry, the cycle runs and records itself
setup; project shop
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "AC-5 contrast: with a project the cycle exits 0" test "$rc" = 0
t "AC-5 contrast: ... dispatches it" grep -qx shop "$tmp/ran"
t "AC-5 contrast: ... and writes one health line" test "$(health_n)" = 1
t "AC-5 contrast: ... that records exit 0 and no overlap" test "$(hcycle)" = "0 False"
t "AC-5 contrast: ... and removes dispatch.pid when it ends" test ! -e "$SHIPFLOOR_HOME/dispatch.pid"

# ---- AC-5: the health line is written on PAUSE, on the usage limit and on an overlap
setup; project shop; touch "$SHIPFLOOR_HOME/PAUSE"
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "AC-5 PAUSE: exit 0" test "$rc" = 0
t "AC-5 PAUSE: nothing dispatched" test "$(ran_n)" = 0
t "AC-5 PAUSE: the health line is written" test "$(health_n)" = 1
t "AC-5 PAUSE: ... with exit 0 and no overlap" test "$(hcycle)" = "0 False"
t "AC-5 PAUSE: dispatch.pid is removed" test ! -e "$SHIPFLOOR_HOME/dispatch.pid"

setup; project shop; mkdir -p "$SHIPFLOOR_HOME/projects/shop/logs"
printf '== start /sf:develop 5\nYou'"'"'ve hit your session limit · resets 6pm\n' > "$SHIPFLOOR_HOME/projects/shop/logs/x-5-develop.log"
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "AC-5 usage limit: exit 0" test "$rc" = 0
t "AC-5 usage limit: nothing dispatched" test "$(ran_n)" = 0
has "$(cat "$tmp/out")" "shipfloor: Claude usage limit hit recently; waiting" "AC-5 usage limit: the cycle says so, with the date first"
t "AC-5 usage limit: the line opens with an ISO date" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+ shipfloor: Claude usage limit' "$tmp/out"
t "AC-5 usage limit: the health line is written" test "$(health_n)" = 1
t "AC-5 usage limit: ... with exit 0 and no overlap" test "$(hcycle)" = "0 False"
# a limit older than 30 minutes, or a log that moved on since the limit, no longer pauses
touch -d '40 minutes ago' "$SHIPFLOOR_HOME/projects/shop/logs/x-5-develop.log"; : > "$tmp/ran"
bash "$MD" >/dev/null 2>&1
t "AC-5 usage limit: a log older than 30 minutes no longer pauses the cycle" grep -qx shop "$tmp/ran"

setup; project shop
echo $$ > "$SHIPFLOOR_HOME/dispatch.pid"   # this test's own shell stands for a cycle still running
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "AC-5 overlap: exit 0" test "$rc" = 0
t "AC-5 overlap: nothing dispatched" test "$(ran_n)" = 0
t "AC-5 overlap: the health line is written" test "$(health_n)" = 1
t "AC-5 overlap: ... recorded as an overlap, exit 0" test "$(hcycle)" = "0 True"
t "AC-5 overlap: the running cycle's dispatch.pid is left alone" test "$(cat "$SHIPFLOOR_HOME/dispatch.pid")" = "$$"

# ---- AC-5: SHIPFLOOR_STALE_LOCK_MIN overrides the 10 minutes
stale_case() {  # stale_case <lock age> [SHIPFLOOR_STALE_LOCK_MIN]: a control behind origin/main with an index.lock of that age; one cycle
  setup; project shop; bash "$MD" >/dev/null 2>&1
  C="$SHIPFLOOR_HOME/projects/shop/control"; LOCK="$(git -C "$C" rev-parse --absolute-git-dir)/index.lock"
  bump 8; : > "$LOCK"; touch -d "$1" "$LOCK"; : > "$tmp/ran"
  OUT="$(SHIPFLOOR_LOCK_RETRY_S=0 env ${2:+SHIPFLOOR_STALE_LOCK_MIN=$2} bash "$MD" 2>&1)"; RC=$?
}
stale_case '5 minutes ago'
t "AC-5 a 5-minute-old index.lock is not stale by default (10 min): it stays" test -e "$LOCK"
t "AC-5 ... the project is skipped (exit 1) and not dispatched" test "$RC-$(ran_n)" = 1-0
stale_case '15 minutes ago'
t "AC-5 a 15-minute-old index.lock is stale by default: removed" test ! -e "$LOCK"
has "$OUT" "removed a stale index.lock (older than 10 min): $LOCK" "AC-5 ... and named in the log with the 10 minutes"
t "AC-5 ... the project is dispatched" grep -qx shop "$tmp/ran"
stale_case '5 minutes ago' 3
t "AC-5 SHIPFLOOR_STALE_LOCK_MIN=3 makes a 5-minute-old index.lock stale: removed" test ! -e "$LOCK"
has "$OUT" "removed a stale index.lock (older than 3 min)" "AC-5 ... the log says 3 min"
t "AC-5 ... the project is dispatched" grep -qx shop "$tmp/ran"
stale_case '15 minutes ago' 30
t "AC-5 SHIPFLOOR_STALE_LOCK_MIN=30 keeps a 15-minute-old index.lock" test -e "$LOCK"
t "AC-5 ... the project is skipped" test "$RC-$(ran_n)" = 1-0

# ---- AC-5: the SKIPPED reason
S_field() { cut -f"$1" "$SHIPFLOOR_HOME/projects/shop/SKIPPED"; }
skipped_ok() {  # the file is one line of "<iso date><TAB><reason>"
  [ "$(grep -c '' "$SHIPFLOOR_HOME/projects/shop/SKIPPED")" = 1 ] && [ "$(awk -F'\t' '{print NF}' "$SHIPFLOOR_HOME/projects/shop/SKIPPED")" = 2 ] &&
    S_field 1 | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+$'
}
# git's own error: a remote that cannot be read. Of its lines only the first fatal/error one is kept.
setup; project shop; bash "$MD" >/dev/null 2>&1
git -C "$R" remote set-url origin "$tmp/no-such-remote"
: > "$tmp/ran"; rm -rf "$SHIPFLOOR_HOME/logs"
OUT="$(bash "$MD" 2>&1)"; RC=$?
reason="$(S_field 2)"
t "AC-5 a git failure: the cycle exits 1" test "$RC" = 1
t "AC-5 a git failure: the project is not dispatched" test "$(ran_n)" = 0
t "AC-5 a git failure: SKIPPED is one line, '<iso date><TAB><reason>'" skipped_ok
t "AC-5 a git failure: the reason is the fixed words and git's first fatal line" test "${reason#cannot bring the control checkout to origin/main: fatal: }" != "$reason"
has "$reason" "does not appear to be a git repository" "AC-5 a git failure: ... that is the line naming the repository"
lacks "$reason" "Could not read from remote repository" "AC-5 a git failure: only the first fatal line is kept, not the second"
t "AC-5 a git failure: the reason is on one line with no tab" test "$(printf '%s' "$reason" | tr -d '\n\t' | wc -c)" = "$(printf '%s' "$reason" | wc -c)"
t "AC-5 a git failure: the log line is '<iso date> shipfloor: shop: <reason>; skipped'" grep -Fq " shipfloor: shop: $reason; skipped" <<< "$OUT"
t "AC-5 a git failure: the health line is written with exit 1" test "$(hfield 'd["cycle"]["exit"]')" = 1
# the first failed cycle's time is kept; the next good cycle clears the file
printf '2026-10-09T20:06:50-03:00\t%s\n' "$reason" > "$SHIPFLOOR_HOME/projects/shop/SKIPPED"
bash "$MD" >/dev/null 2>&1
t "AC-5 a second failed cycle keeps the first time" test "$(S_field 1)" = "2026-10-09T20:06:50-03:00"
git -C "$R" remote set-url origin "$REMOTE"
bash "$MD" >/dev/null 2>&1; rc=$?
t "AC-5 a good cycle after it exits 0 and removes SKIPPED" test "$rc-$([ -e "$SHIPFLOOR_HOME/projects/shop/SKIPPED" ] && echo kept || echo gone)" = 0-gone
t "AC-5 ... and dispatches the project again" grep -qx shop "$tmp/ran"

# a main with no config
setup; project shop -
OUT="$(bash "$MD" 2>&1)"; RC=$?
t "AC-5 no config on origin/main: the cycle exits 1" test "$RC" = 1
t "AC-5 no config on origin/main: SKIPPED is one line, '<iso date><TAB><reason>'" skipped_ok
t "AC-5 no config on origin/main: the reason is 'no .shipfloor/factory.yml on origin/main'" test "$(S_field 2)" = "no .shipfloor/factory.yml on origin/main"
t "AC-5 no config on origin/main: the log line says so, then '; skipped'" grep -Fq " shipfloor: shop: no .shipfloor/factory.yml on origin/main; skipped" <<< "$OUT"
t "AC-5 no config on origin/main: not dispatched" test "$(ran_n)" = 0
# a config that does not validate
setup; project shop 'project: {name: broken}'
OUT="$(bash "$MD" 2>&1)"; RC=$?
t "AC-5 an invalid config: the cycle exits 1" test "$RC" = 1
t "AC-5 an invalid config: SKIPPED is one line, '<iso date><TAB><reason>'" skipped_ok
t "AC-5 an invalid config: the reason is 'invalid .shipfloor/factory.yml on origin/main'" test "$(S_field 2)" = "invalid .shipfloor/factory.yml on origin/main"
t "AC-5 an invalid config: not dispatched" test "$(ran_n)" = 0
finish
