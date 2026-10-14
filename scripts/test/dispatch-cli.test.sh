#!/usr/bin/env bash
# suite: integration
# The dispatcher's entry points through their real wrappers (the logic is in process: py/dispatch_*.py):
#  - dispatch.sh is `sf.py dispatch`: same text and exit code; an installed copy without lib/stack.sh or lib/project.sh,
#    runs a cycle with cost limits, gives back the run's stack slot, writes no __pycache__; lib/project.sh's tmp sweep
#  - shipfloor-dispatch.sh (`sf.py cycle`): one cycle over several projects, each in its own process; a project that
#    is skipped or whose process dies does not stop the others; two cycles at once: exactly one dispatches
#  - run-dispatcher.sh, the scheduled task: PAUSE, the log it appends both streams to, PATH from dispatcher.path,
#    the cycle's exit status, and a cycle under `env -i`
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
D="$FACTORY_DIR/dispatch.sh"; MD="$FACTORY_DIR/shipfloor-dispatch.sh"; RD="$FACTORY_DIR/run-dispatcher.sh"
PY="$FACTORY_PYTHON"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }

# ---- dispatch.sh and sf.py dispatch are the same command
bad="$(mktemp -d)"; echo 'project: {name: shop}' > "$bad/factory.yml"
a="$(FACTORY_CONFIG="$bad/factory.yml" bash "$D" 2>&1)"; ra=$?
b="$(FACTORY_CONFIG="$bad/factory.yml" "$PY" -I "$FACTORY_DIR/sf.py" dispatch 2>&1)"; rb=$?
t "an invalid config: dispatch.sh and sf.py dispatch both exit 2" test "$ra-$rb" = 2-2
t "... with the same text" test "$a" = "$b"
assert_contains "$a" "dispatch: invalid config $bad/factory.yml"

# ---- an installed copy without lib/stack.sh and lib/project.sh, with cost limits on
unset PYTHONDONTWRITEBYTECODE
inst="$(plugin_copy)"; rm -f "$inst/scripts/lib/stack.sh" "$inst/scripts/lib/project.sh"
t "the installed copy starts with no __pycache__" test -z "$(find "$inst" -name __pycache__)"
export SHIPFLOOR_HOME="$(mktemp -d)"
export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
tmp="$(mktemp -d)"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks"
printf 'pool: 4\ncosts:\n  card_block: 40\n  day_stop: 500\n' > "$SHIPFLOOR_HOME/config.yml"
printf '#!/usr/bin/env bash\ncase "$1 ${2:-}" in "eligible Ready for Dev") echo 26 ;; "count "*) echo 0 ;; *) echo ;; esac\n' > "$tmp/board"
cat > "$tmp/claude" <<'EOC'
#!/usr/bin/env bash
cat > /dev/null
mkdir -p "$SHIPFLOOR_HOME/locks/stack-0.lock"
echo "develop-26 $SHIPFLOOR_RUN_LOCK $(date +%s)" > "$SHIPFLOOR_HOME/locks/stack-0.lock/info"
echo ran >> "$(dirname "$0")/ran"
EOC
chmod +x "$tmp/board" "$tmp/claude"; export FACTORY_BOARD="$tmp/board" FACTORY_CLAUDE="$tmp/claude"
D="$inst/scripts/dispatch.sh"
out="$(run_dispatch 2>&1)"; rc=$?
t "the installed copy's cycle exits 0 and starts the run" test "$rc" = 0 -a -s "$tmp/ran"
t "... whose stack slot is released and lock gone when it ends" test ! -d "$SHIPFLOOR_HOME/locks/stack-0.lock" -a ! -d "$FACTORY_HOME/locks/develop-26.lock"
lacks_err() { case "$out" in *"No such file"*|*"command not found"*) return 1 ;; esac; return 0; }
t "... with no missing-file or missing-command error" lacks_err
t "... and no bytecode written under the installed copy (the cost estimate ran)" test -z "$(find "$inst" -name __pycache__ -o -name '*.pyc')"

# ---- the tmp sweep through lib/project.sh (what `shipfloor clean` runs): it prints each thing it removed
mkdir -p "$FACTORY_HOME/tmp/5" "$FACTORY_HOME/tmp/6"; printf '5\tDone\tI5\n6\tCoding\tI6\n' > "$FACTORY_HOME/board.tsv"
t "shipfloor_sweep_tmp removes a Done card's tmp/<n>/ and prints it" test "$(source "$FACTORY_DIR/lib/project.sh"; shipfloor_sweep_tmp)|$(ls "$FACTORY_HOME/tmp")" = "tmp/5|6"
unset FACTORY_HOME FACTORY_CONTROL_REFRESH FACTORY_WT_ROOT FACTORY_PROJECT FACTORY_BOARD FACTORY_CLAUDE FACTORY_CONFIG

# ---- the machine-wide cycle over the registry
setup() {  # a new SHIPFLOOR_HOME, and a dispatch stub that notes each project it runs for
  export SHIPFLOOR_HOME="$(mktemp -d)"; tmp="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "$FACTORY_PROJECT $FACTORY_CONTROL_REFRESH" >> "%s/ran"\n' "$tmp" > "$tmp/dispatch"
  chmod +x "$tmp/dispatch"; export SHIPFLOOR_DISPATCH="$tmp/dispatch"; : > "$tmp/ran"
}
project() {  # project <slug> [config text | -]: a repo with a remote whose main carries .shipfloor/factory.yml ("-": none)
  local slug="$1" cfg="${2:-}" remote r
  remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"
  if [ "$cfg" != - ]; then
    mkdir -p "$r/.shipfloor"
    if [ -n "$cfg" ]; then printf '%s\n' "$cfg" > "$r/.shipfloor/factory.yml"
    else sed "s/name: shop/name: $slug/" "$FACTORY_DIR/test/fixture/factory.yml" > "$r/.shipfloor/factory.yml"; fi
    git -C "$r" add -A; git -C "$r" commit -qm cfg
  fi
  git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$r" "$SHIPFLOOR_HOME/projects/$slug/wt" >> "$SHIPFLOOR_HOME/registry.tsv"
}
health() { cat "$SHIPFLOOR_HOME"/logs/health-*.jsonl 2>/dev/null; }

setup; project shop; project blog
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "shipfloor-dispatch.sh: two good projects, exit 0" test "$rc" = 0
t "... each dispatched once, told not to refresh its control checkout again" test "$(sort "$tmp/ran" | tr '\n' ' ')" = "blog 0 shop 0 "
t "... their control checkouts made" test -f "$SHIPFLOOR_HOME/projects/blog/control/.shipfloor/factory.yml"
t "... one health line, and dispatch.pid gone" test "$(health | grep -c .)" = 1 -a ! -e "$SHIPFLOOR_HOME/dispatch.pid"

# a skipped project and one whose dispatch kills the process it runs in do not stop the others (sf.py cycle, run directly)
setup; project broken 'project: {name: broken}'; project crash; project shop
cat > "$tmp/dispatch" <<EOS
#!/usr/bin/env bash
echo "\$FACTORY_PROJECT" >> "$tmp/ran"
[ "\$FACTORY_PROJECT" = crash ] && kill -9 "\$PPID"
exit 0
EOS
"$PY" -I "$(nat "$FACTORY_DIR/sf.py")" cycle >"$tmp/out" 2>&1; rc=$?
t "sf.py cycle with a broken and a crashing project exits 1" test "$rc" = 1
t "... the next project still runs, the broken one is not dispatched" test "$(tr '\n' ' ' < "$tmp/ran")" = "crash shop "
assert_contains "$(cat "$tmp/out")" "shipfloor: broken: invalid .shipfloor/factory.yml on origin/main; skipped"
t "... the health line records exit 1, and dispatch.pid is gone" test "$(health | grep -c '"exit": 1')" = 1 -a ! -e "$SHIPFLOOR_HOME/dispatch.pid"

# two cycles that start at once race for dispatch.pid: exactly one dispatches
setup; project shop
bash "$MD" >/dev/null 2>&1; : > "$tmp/ran"  # the control checkout exists before the race
printf '#!/usr/bin/env bash\necho "$FACTORY_PROJECT" >> "%s/ran"\nsleep 1\n' "$tmp" > "$tmp/dispatch"
bash "$MD" >/dev/null 2>&1 & p1=$!
bash "$MD" >/dev/null 2>&1 & p2=$!
wait "$p1"; c1=$?; wait "$p2"; c2=$?
t "two simultaneous cycles: exactly one dispatches, both exit 0" test "$(grep -c . "$tmp/ran")-$c1-$c2" = 1-0-0
t "... the other is recorded as an overlap, and dispatch.pid is gone" test "$(health | grep -c '"overlap": true')" = 1 -a ! -e "$SHIPFLOOR_HOME/dispatch.pid"

# ---- run-dispatcher.sh, the scheduled task's entry point
rsetup() {  # setup with a stub that writes on both streams, notes its PATH and looks for a probe tool
  setup
  cat > "$tmp/dispatch" <<'EOS'
#!/usr/bin/env bash
echo "stub: out line for $FACTORY_PROJECT"
echo "stub: err line for $FACTORY_PROJECT" >&2
echo "$PATH" > "$STUB_TMP/path"
echo "$TMPDIR" > "$STUB_TMP/tmpdir"
command -v shipfloor-probe > "$STUB_TMP/probe" 2>&1
echo "$FACTORY_PROJECT" >> "$STUB_TMP/ran"
EOS
  export STUB_TMP="$tmp"; mkdir -p "$tmp/tools"; printf '#!/bin/sh\n' > "$tmp/tools/shipfloor-probe"; chmod +x "$tmp/tools/shipfloor-probe"
}
dlog="logs/dispatcher.log"
rsetup; project shop; touch "$SHIPFLOOR_HOME/PAUSE"
bash "$RD" >"$tmp/console" 2>&1; rc=$?
t "PAUSE: exit 0, nothing dispatched, nothing on the terminal" test "$rc" = 0 -a ! -s "$tmp/ran" -a ! -s "$tmp/console"
t "PAUSE: no health line and no dispatch.pid (shipfloor-dispatch.sh is never started)" test -z "$(health)" -a ! -e "$SHIPFLOOR_HOME/dispatch.pid"
t "PAUSE: the log file is made (the redirect comes first), empty" test -f "$SHIPFLOOR_HOME/$dlog" -a ! -s "$SHIPFLOOR_HOME/$dlog"

rsetup; project shop; mkdir -p "$SHIPFLOOR_HOME/logs"; echo "an earlier cycle's line" > "$SHIPFLOOR_HOME/$dlog"
printf '%s\n%s\n' "$tmp/tools" "/second/line/is/ignored" > "$SHIPFLOOR_HOME/dispatcher.path"
bash "$RD" >"$tmp/console" 2>"$tmp/console-err"; rc=$?
t "a cycle: exit 0, a health line" test "$rc" = 0 -a "$(health | grep -c .)" = 1
t "... its stdout and stderr appended to dispatcher.log" test "$(sed -n 1p "$SHIPFLOOR_HOME/$dlog")|$(grep -c -x -e 'stub: out line for shop' -e 'stub: err line for shop' "$SHIPFLOOR_HOME/$dlog")" = "an earlier cycle's line|2"
t "... and neither stream reaches the terminal" test ! -s "$tmp/console" -a ! -s "$tmp/console-err"
t "... its PATH opens with the first line of dispatcher.path, then the task's own" test "$(cat "$tmp/path")" = "$tmp/tools:$PATH"
t "... where a tool is found" test "$(cat "$tmp/probe")" = "$tmp/tools/shipfloor-probe"

# AC-1 AC-2: the cycle's TMPDIR is <SHIPFLOOR_HOME>/tmp, made if missing, whatever TMPDIR the scheduler or the shell gave
rsetup; project shop; mkdir -p "$tmp/inherited"; : > "$SHIPFLOOR_HOME/dispatcher.path"
t "AC-1 the tmp folder does not exist before the cycle" test ! -e "$SHIPFLOOR_HOME/tmp"
TMPDIR="$tmp/inherited" bash "$RD" >/dev/null 2>&1
t "AC-1 AC-2 a cycle with another TMPDIR inherited gets <SHIPFLOOR_HOME>/tmp, which exists" test "$(cat "$tmp/tmpdir")|$([ -d "$SHIPFLOOR_HOME/tmp" ] && echo dir)" = "$SHIPFLOOR_HOME/tmp|dir"
rm -rf "$SHIPFLOOR_HOME/tmp"; : > "$tmp/tmpdir"
env -u TMPDIR bash "$RD" >/dev/null 2>&1
t "AC-1 AC-2 ... also with no TMPDIR at all, and a missing folder is made again" test "$(cat "$tmp/tmpdir")" = "$SHIPFLOOR_HOME/tmp" -a -d "$SHIPFLOOR_HOME/tmp"

rsetup; project shop -; : > "$SHIPFLOOR_HOME/dispatcher.path"
bash "$RD" >"$tmp/console" 2>"$tmp/console-err"; rc=$?
t "a skipped project: run-dispatcher.sh exits with the cycle's status (1), the terminal silent" test "$rc" = 1 -a ! -s "$tmp/console" -a ! -s "$tmp/console-err"
t "... its 'skipped' line (stderr) is in dispatcher.log" grep -q 'shipfloor: shop: no .shipfloor/factory.yml on origin/main; skipped' "$SHIPFLOOR_HOME/$dlog"

setup
bash "$RD" >"$tmp/console" 2>&1; rc=$?
t "an empty registry: exit 0, the log made and empty" test "$rc" = 0 -a -f "$SHIPFLOOR_HOME/$dlog" -a ! -s "$SHIPFLOOR_HOME/$dlog"

# the scheduled entry with an `env -i` environment and dispatcher.path runs a cycle that launches the stub. HOME stays
# the real one, as the scheduler gives it: Python finds packages installed for the user, like the CI's PyYAML
setup; project shop
printf '%s\n' "$PATH" > "$SHIPFLOOR_HOME/dispatcher.path"
env -i HOME="$HOME" SHIPFLOOR_HOME="$SHIPFLOOR_HOME" SHIPFLOOR_DISPATCH="$SHIPFLOOR_DISPATCH" PATH=/usr/bin:/bin \
  ${SYSTEMROOT:+SYSTEMROOT="$SYSTEMROOT"} bash -l "$RD" >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 0 ] || sed "s/^/  out: /" "$SHIPFLOOR_HOME/$dlog" >&2  # what the scheduled entry logged, when it failed
t "env -i: exit 0, nothing on the terminal" test "$rc" = 0 -a ! -s "$tmp/out"
t "env -i: the cycle launched the stub and wrote the health line" test "$(cat "$tmp/ran")|$(health | grep -c .)" = "shop 0|1"
finish
