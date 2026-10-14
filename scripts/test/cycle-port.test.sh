#!/usr/bin/env bash
# #169: the machine-wide cycle lives in shipfloor_core/cycle.py; shipfloor-dispatch.sh is a thin wrapper.
# The cycle's behavior is pinned, unedited, by shipfloor-dispatch.test.sh, shipfloor-dispatch-cycle.test.sh,
# health.test.sh, notify*.test.sh, run-dispatcher.test.sh and install-dispatcher.test.sh; this file checks the port:
#  - AC-8 `sf.py cycle` run directly is the whole cycle (dispatches, writes the health line, removes dispatch.pid)
#  - AC-6/7 each project runs in its own process: one whose dispatch kills that process does not stop the others
#  - AC-8 the scheduled entry with an `env -i`-like environment and dispatcher.path runs a cycle that launches a stub run
# Safety: a failing mktemp aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
MD="$FACTORY_DIR/shipfloor-dispatch.sh"
PY="$FACTORY_PYTHON"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }

setup() {  # setup: a new SHIPFLOOR_HOME, with a dispatch stub that notes each project it is run for
  export SHIPFLOOR_HOME="$(mktemp -d)"; tmp="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "$FACTORY_PROJECT $FACTORY_CONTROL_REFRESH" >> "%s/ran"\n' "$tmp" > "$tmp/dispatch"
  chmod +x "$tmp/dispatch"; export SHIPFLOOR_DISPATCH="$tmp/dispatch"; : > "$tmp/ran"
}
project() {  # project <slug>: a repo with a remote whose main carries .shipfloor/factory.yml
  local slug="$1" remote r
  remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.shipfloor"
  sed "s/name: shop/name: $slug/" "$FACTORY_DIR/test/fixture/factory.yml" > "$r/.shipfloor/factory.yml"
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$r" "$SHIPFLOOR_HOME/projects/$slug/wt" >> "$SHIPFLOOR_HOME/registry.tsv"
}
health() { cat "$SHIPFLOOR_HOME"/logs/health-*.jsonl 2>/dev/null; }

# ---- AC-8: sf.py cycle, run directly, is the cycle
setup; project shop
"$PY" -I "$(nat "$FACTORY_DIR/sf.py")" cycle >"$tmp/out" 2>&1; rc=$?
t "AC-8 sf.py cycle exits 0 with one good project" test "$rc" = 0
t "AC-8 sf.py cycle dispatches it with FACTORY_CONTROL_REFRESH=0" grep -qx 'shop 0' "$tmp/ran"
t "AC-8 sf.py cycle writes one health line" test "$(health | grep -c .)" = 1
t "AC-8 sf.py cycle removes dispatch.pid" test ! -e "$SHIPFLOOR_HOME/dispatch.pid"
t "AC-8 sf.py cycle brought the control checkout up" test -f "$SHIPFLOOR_HOME/projects/shop/control/.shipfloor/factory.yml"

# ---- AC-6/AC-7: a project whose dispatch kills the process it runs in does not stop the others
setup; project crash; project shop
cat > "$tmp/dispatch" <<EOS
#!/usr/bin/env bash
echo "\$FACTORY_PROJECT" >> "$tmp/ran"
[ "\$FACTORY_PROJECT" = crash ] && kill -9 "\$PPID"
exit 0
EOS
bash "$MD" >"$tmp/out" 2>&1; rc=$?
t "AC-7 a project whose dispatch kills its process: the cycle exits 1" test "$rc" = 1
t "AC-6 ... the next project still runs" grep -qx shop "$tmp/ran"
t "AC-4 ... and the health line is written with exit 1" grep -q '"exit": 1' <(health)
t "AC-3 ... and dispatch.pid is removed" test ! -e "$SHIPFLOOR_HOME/dispatch.pid"

# ---- AC-8: the scheduled entry, env -i with dispatcher.path, runs a cycle that launches a stub run
setup; project shop
mkdir -p "$SHIPFLOOR_HOME"
printf '%s\n' "$PATH" > "$SHIPFLOOR_HOME/dispatcher.path"
# HOME stays the real one, as the scheduler gives it (install-dispatcher.test.sh does the same): Python finds
# packages installed for the user, like the CI's pip-installed PyYAML
env -i HOME="$HOME" SHIPFLOOR_HOME="$SHIPFLOOR_HOME" SHIPFLOOR_DISPATCH="$SHIPFLOOR_DISPATCH" PATH=/usr/bin:/bin \
  ${SYSTEMROOT:+SYSTEMROOT="$SYSTEMROOT"} bash -l "$FACTORY_DIR/run-dispatcher.sh" >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 0 ] || sed "s/^/  out: /" "$tmp/out" >&2  # what the scheduled entry printed, when it failed
t "AC-8 env -i: the scheduled entry exits 0" test "$rc" = 0
t "AC-8 env -i: nothing reaches the terminal" test ! -s "$tmp/out"
t "AC-8 env -i: the cycle launched the stub run" grep -qx 'shop 0' "$tmp/ran"
t "AC-8 env -i: the health line is written" test "$(health | grep -c .)" = 1
finish
