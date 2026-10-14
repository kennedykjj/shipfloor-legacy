#!/usr/bin/env bash
# #168 AC-8: dispatch.sh and `sf.py dispatch` are the same command, and a factory without lib/stack.sh or lib/project.sh
# still runs a cycle, whose run gives back the stack slot it held (dispatch.py calls stack.py itself). That dispatch.sh is
# a thin wrapper is hygiene.test.sh's.
# Safety: a failing mktemp (no space or inodes in /tmp) aborts the whole test at once, never handing back an empty path.
mktemp() { local d; d="$(command mktemp "$@")" && [ -n "$d" ] && [ -e "$d" ] || { echo "FAIL cannot create a temp dir" >&2; kill -TERM "$$"; exit 1; }; printf '%s\n' "$d"; }
source "$(dirname "$0")/lib.sh"
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
W="$FACTORY_DIR/dispatch.sh"

# ---- sf.py dispatch and the wrapper are the same command: same text, same exit code
bad="$(mktemp -d)"; echo 'project: {name: shop}' > "$bad/factory.yml"
a="$(FACTORY_CONFIG="$bad/factory.yml" bash "$W" 2>&1)"; ra=$?
b="$(FACTORY_CONFIG="$bad/factory.yml" "$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" dispatch 2>&1)"; rb=$?
t "AC-8 sf.py dispatch is a command (no usage line)" not grep -q 'usage: sf.py' <<< "$b"
t "AC-8 an invalid config: the wrapper exits 2" test "$ra" = 2
t "AC-8 ... and sf.py dispatch exits 2 too" test "$rb" = 2
t "AC-8 ... with the same text" test "$a" = "$b"
assert_contains "$a" "dispatch: invalid config $bad/factory.yml"

# ---- a factory without lib/stack.sh and lib/project.sh still dispatches, and the run gives back its stack slot
inst="$(plugin_copy)"; rm -f "$inst/scripts/lib/stack.sh" "$inst/scripts/lib/project.sh"
export SHIPFLOOR_HOME="$(mktemp -d)"
export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
tmp="$(mktemp -d)"; S="$SHIPFLOOR_HOME/locks"; mkdir -p "$FACTORY_HOME/control" "$FACTORY_HOME/locks"
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
t "AC-8 without lib/stack.sh and lib/project.sh the cycle exits 0" test "$rc" = 0
t "AC-8 ... and starts the run" test -s "$tmp/ran"
t "AC-8 ... whose stack slot is released when it ends" test ! -d "$S/stack-0.lock"
t "AC-8 ... and whose lock is gone" test ! -d "$FACTORY_HOME/locks/develop-26.lock"
lacks_err() { case "$out" in *"No such file"*|*"command not found"*) return 1 ;; esac; return 0; }
t "AC-8 ... with no missing-file or missing-command error" lacks_err
finish
