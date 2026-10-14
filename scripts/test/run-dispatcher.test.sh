#!/usr/bin/env bash
# #160 AC-6: run-dispatcher.sh, the scheduled task's entry point, pinned as it is today.
#  - PAUSE: exit 0 with no health line (it stops before shipfloor-dispatch.sh, which would record one)
#  - stdout and stderr of the whole cycle are appended to logs/dispatcher.log, nothing reaches the terminal
#  - PATH comes from the first line of dispatcher.path, put in front of the PATH the task started with
source "$(dirname "$0")/lib.sh"
RD="$FACTORY_DIR/run-dispatcher.sh"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }

setup() {  # setup: a new SHIPFLOOR_HOME with one registered project and a dispatch stub that writes on both streams, notes its PATH and looks for a probe tool
  export SHIPFLOOR_HOME="$(mktemp -d)"; tmp="$(mktemp -d)"
  cat > "$tmp/dispatch" <<'EOS'
#!/usr/bin/env bash
echo "stub: out line for $FACTORY_PROJECT"
echo "stub: err line for $FACTORY_PROJECT" >&2
echo "$PATH" > "$STUB_TMP/path"
command -v shipfloor-probe > "$STUB_TMP/probe" 2>&1
echo "$FACTORY_PROJECT" >> "$STUB_TMP/ran"
EOS
  chmod +x "$tmp/dispatch"; export SHIPFLOOR_DISPATCH="$tmp/dispatch" STUB_TMP="$tmp"; : > "$tmp/ran"
  mkdir -p "$tmp/tools"; printf '#!/bin/sh\n' > "$tmp/tools/shipfloor-probe"; chmod +x "$tmp/tools/shipfloor-probe"
}
project() {  # project <slug> [-]: a repo with a remote whose main carries .shipfloor/factory.yml ("-": without it)
  local slug="$1" remote r
  remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"
  if [ "${2:-}" != - ]; then
    mkdir -p "$r/.shipfloor"; sed "s/name: shop/name: $slug/" "$FACTORY_DIR/test/fixture/factory.yml" > "$r/.shipfloor/factory.yml"
    git -C "$r" add -A; git -C "$r" commit -qm cfg
  fi
  git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$r" "$SHIPFLOOR_HOME/projects/$slug/wt" >> "$SHIPFLOOR_HOME/registry.tsv"
}
dlog() { cat "$SHIPFLOOR_HOME/logs/dispatcher.log" 2>/dev/null; }
health_n() { cat "$SHIPFLOOR_HOME"/logs/health-*.jsonl 2>/dev/null | grep -c .; }

# ---- AC-6: PAUSE exits 0 with no health line
setup; project shop; touch "$SHIPFLOOR_HOME/PAUSE"
bash "$RD" >"$tmp/console" 2>&1; rc=$?
t "AC-6 PAUSE: exit 0" test "$rc" = 0
t "AC-6 PAUSE: no health line (shipfloor-dispatch.sh is never started)" test "$(health_n)" = 0
t "AC-6 PAUSE: nothing is dispatched" test ! -s "$tmp/ran"
t "AC-6 PAUSE: no dispatch.pid" test ! -e "$SHIPFLOOR_HOME/dispatch.pid"
t "AC-6 PAUSE: the log file is made (the redirect comes first), empty" test -f "$SHIPFLOOR_HOME/logs/dispatcher.log" -a ! -s "$SHIPFLOOR_HOME/logs/dispatcher.log"
t "AC-6 PAUSE: nothing reaches the terminal" test ! -s "$tmp/console"
# contrast: the same home without PAUSE records a health line
setup; project shop
bash "$RD" >"$tmp/console" 2>&1; rc=$?
t "AC-6 contrast: without PAUSE the cycle exits 0" test "$rc" = 0
t "AC-6 contrast: ... dispatches the project" grep -qx shop "$tmp/ran"
t "AC-6 contrast: ... and writes a health line" test "$(health_n)" = 1

# ---- AC-6: stdout and stderr appended to logs/dispatcher.log
setup; project shop; mkdir -p "$SHIPFLOOR_HOME/logs"; echo "an earlier cycle's line" > "$SHIPFLOOR_HOME/logs/dispatcher.log"
bash "$RD" >"$tmp/console" 2>"$tmp/console-err"; rc=$?
t "AC-6 a normal run exits 0" test "$rc" = 0
t "AC-6 stdout of the cycle is in dispatcher.log" grep -qx 'stub: out line for shop' "$SHIPFLOOR_HOME/logs/dispatcher.log"
t "AC-6 stderr of the cycle is in dispatcher.log" grep -qx 'stub: err line for shop' "$SHIPFLOOR_HOME/logs/dispatcher.log"
t "AC-6 the log is appended to: the earlier line is still first" test "$(sed -n 1p "$SHIPFLOOR_HOME/logs/dispatcher.log")" = "an earlier cycle's line"
t "AC-6 neither stream reaches the terminal (stdout)" test ! -s "$tmp/console"
t "AC-6 neither stream reaches the terminal (stderr)" test ! -s "$tmp/console-err"
bash "$RD" >/dev/null 2>&1
t "AC-6 a second cycle appends again: two out lines and two err lines" test "$(grep -c '^stub: ' "$SHIPFLOOR_HOME/logs/dispatcher.log")" = 4
t "AC-6 ... and still holds the first line" test "$(sed -n 1p "$SHIPFLOOR_HOME/logs/dispatcher.log")" = "an earlier cycle's line"
# the cycle's own messages (stderr) go to the log too, and its exit status is the cycle's
setup; project shop -
bash "$RD" >"$tmp/console" 2>"$tmp/console-err"; rc=$?
t "AC-6 a skipped project: run-dispatcher.sh exits with the cycle's status (1)" test "$rc" = 1
t "AC-6 ... its 'skipped' line (stderr) is in dispatcher.log" grep -q 'shipfloor: shop: no .shipfloor/factory.yml on origin/main; skipped' "$SHIPFLOOR_HOME/logs/dispatcher.log"
t "AC-6 ... and the terminal stays silent" test ! -s "$tmp/console" -a ! -s "$tmp/console-err"
# an empty registry: the cycle returns at once; the log file still exists
setup
bash "$RD" >"$tmp/console" 2>&1; rc=$?
t "AC-6 an empty registry exits 0, the log made and empty" test "$rc" = 0 -a -f "$SHIPFLOOR_HOME/logs/dispatcher.log" -a ! -s "$SHIPFLOOR_HOME/logs/dispatcher.log"

# ---- AC-6: PATH comes from dispatcher.path
setup; project shop
echo "$tmp/tools" > "$SHIPFLOOR_HOME/dispatcher.path"
bash "$RD" >/dev/null 2>&1
t "AC-6 dispatcher.path: the cycle's PATH opens with its line, then the task's own PATH" test "$(cat "$tmp/path")" = "$tmp/tools:$PATH"
t "AC-6 dispatcher.path: a tool in that folder is found by the cycle" test "$(cat "$tmp/probe")" = "$tmp/tools/shipfloor-probe"
setup; project shop
printf '%s\n%s\n' "$tmp/tools" "/second/line/is/ignored" > "$SHIPFLOOR_HOME/dispatcher.path"
bash "$RD" >/dev/null 2>&1
t "AC-6 dispatcher.path: only its first line is used" test "$(cat "$tmp/path")" = "$tmp/tools:$PATH"
setup; project shop
bash "$RD" >/dev/null 2>&1
t "AC-6 no dispatcher.path: PATH is the task's own" test "$(cat "$tmp/path")" = "$PATH"
t "AC-6 no dispatcher.path: the probe tool is not found" test ! -s "$tmp/probe" -o "$(cat "$tmp/probe")" != "$tmp/tools/shipfloor-probe"
setup; project shop
: > "$SHIPFLOOR_HOME/dispatcher.path"
bash "$RD" >/dev/null 2>&1
t "AC-6 an empty dispatcher.path leaves PATH as it was" test "$(cat "$tmp/path")" = "$PATH"
finish
