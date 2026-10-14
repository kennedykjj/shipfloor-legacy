#!/usr/bin/env bash
# The installed copy and the Python package (#162):
#   AC-3  no __pycache__ in the installed copy: not after sf.py runs, not copied by install, not a difference for doctor
#   AC-8  shipfloor doctor fails with one clear line naming the 3.11 minimum when the factory's Python is 3.10
source "$(dirname "$0")/lib.sh"
export GIT_TERMINAL_PROMPT=0
T="$(mktemp -d)"

put_plugin() {  # put_plugin <dir>: a plain copy of scripts/ (no tests) and templates/, no __pycache__ in it
  local c; c="$(plugin_copy)"; mv "$c/scripts" "$1/scripts"; mv "$c/templates" "$1/templates"
}
run_sf() {  # run_sf <src> <home> <args...>: OUT = stdout and stderr, RC
  local src="$1" home="$2"; shift 2
  OUT="$(SHIPFLOOR_HOME="$home" bash "$src/scripts/shipfloor" "$@" 2>&1)"; RC=$?
}
pycaches() { find "$1" -name __pycache__ -o -name '*.pyc' 2>/dev/null | head -5 | tr '\n' ' '; }

# ---- AC-3
src="$T/src1"; mkdir -p "$src"; put_plugin "$src"; home="$T/home1"; mkdir -p "$home"
mkdir -p "$src/scripts/shipfloor_core/__pycache__" "$src/scripts/__pycache__"
echo junk > "$src/scripts/shipfloor_core/__pycache__/proc.cpython-311.pyc"; echo junk > "$src/scripts/__pycache__/sf.cpython-311.pyc"

t="AC-3 install does not copy a __pycache__"
run_sf "$src" "$home" install
[ "$RC" -eq 0 ] && pass "$t: install exits 0" || fail "$t: install exits $RC: $OUT"
[ -f "$home/factory/gate.sh" ] && pass "$t: installed" || fail "$t: nothing was installed"
[ -f "$home/factory/sf.py" ] && [ -f "$home/factory/shipfloor_core/__init__.py" ] && pass "$t: the package is installed" || fail "$t: sf.py or shipfloor_core is not in the installed copy"
[ -z "$(pycaches "$home/factory")" ] && pass "$t: no __pycache__ under the installed copy" || fail "$t: copied: $(pycaches "$home/factory")"

t="AC-3 sf.py leaves no __pycache__ in the installed copy"
cp "$src/templates/py-wrapper.sh" "$home/factory/wrap.sh" 2>/dev/null || fail "$t: templates/py-wrapper.sh does not exist"
bash "$home/factory/wrap.sh" version >/dev/null 2>&1
[ -f "$home/factory/sf.py" ] && pass "$t: sf.py ran from the installed copy" || fail "$t: no sf.py in the installed copy"
[ -z "$(pycaches "$home/factory")" ] && pass "$t: no __pycache__ after sf.py ran" || fail "$t: left: $(pycaches "$home/factory")"

t="AC-3 doctor does not report a __pycache__ as a difference"
rm -f "$home/factory/wrap.sh"; rm -f "$src/scripts/wrap.sh"
run_sf "$src" "$home" install
# the source side gains one (a checkout that ran sf.py from source) and so does the installed side (an older run)
mkdir -p "$src/scripts/shipfloor_core/__pycache__"; echo more > "$src/scripts/shipfloor_core/__pycache__/text.cpython-311.pyc"
mkdir -p "$home/factory/__pycache__"; echo old > "$home/factory/__pycache__/sf.cpython-311.pyc"
run_sf "$src" "$home" doctor
case "$OUT" in *"ok   installed copy matches"*) pass "$t: installed copy matches" ;; *) fail "$t: doctor does not say the copy matches: $OUT" ;; esac
case "$OUT" in *"installed copy differs"*) fail "$t: doctor reports a difference: $OUT" ;; *) pass "$t: no 'differs' warning" ;; esac

t="AC-3 doctor still reports a real difference"
echo "# edited" >> "$src/scripts/gate.sh"
run_sf "$src" "$home" doctor
case "$OUT" in *"WARN installed copy differs"*) pass "$t" ;; *) fail "$t: no 'differs' warning for an edited gate.sh: $OUT" ;; esac

# ---- AC-8: a stub standing for Python 3.10: the real interpreter, reporting itself as 3.10.12
cat > "$T/py310" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --version|-V) echo "Python 3.10.12"; exit 0 ;; esac
exec "$REAL_PY" -I -c '
import collections, runpy, sys
V = collections.namedtuple("version_info", "major minor micro releaselevel serial")
sys.version_info = V(3, 10, 12, "final", 0)
sys.version = "3.10.12 (main, stub) [GCC]"
sys.hexversion = 0x030A0CF0
a = sys.argv[1:]
while a and a[0] in ("-I", "-B", "-E", "-s", "-S", "-u"):
    a = a[1:]
if a and a[0] == "--version":
    print("Python 3.10.12"); sys.exit(0)
if a and a[0] == "-c":
    sys.argv = ["-c"] + a[2:]
    exec(compile(a[1], "<string>", "exec"), {"__name__": "__main__"})
elif a and a[0] == "-m":
    sys.argv = a[1:]
    runpy.run_module(a[1], run_name="__main__", alter_sys=True)
elif a:
    sys.argv = a
    runpy.run_path(a[0], run_name="__main__")
' "$@"
EOF
chmod +x "$T/py310"
export REAL_PY="$FACTORY_PYTHON"
real_ok="$("$FACTORY_PYTHON" -c 'import sys; print(int(sys.version_info >= (3, 11)))')"
stub_ver="$("$T/py310" -c 'import sys; print(sys.version_info[:2])')"
[ "$stub_ver" = "(3, 10)" ] && pass "the 3.10 stub reports (3, 10)" || fail "the test's 3.10 stub is broken: $stub_ver"

src="$T/src2"; mkdir -p "$src"; put_plugin "$src"; home="$T/home2"; mkdir -p "$home"
run_sf "$src" "$home" install

t="AC-8 doctor on Python 3.10 fails naming the 3.11 minimum"
OUT="$(FACTORY_PYTHON="$T/py310" SHIPFLOOR_HOME="$home" bash "$src/scripts/shipfloor" doctor 2>&1)"; RC=$?
n="$(printf '%s\n' "$OUT" | grep -c '^FAIL .*3\.11')"
[ "$n" = 1 ] && pass "$t: one FAIL line names 3.11" || fail "$t: want one 'FAIL ...3.11' line, got $n in: $OUT"
[ "$RC" -ne 0 ] && pass "$t: doctor exits non-zero" || fail "$t: doctor exits 0"
case "$OUT" in *"3.10"*) pass "$t: the line says which version it found" ;; *) fail "$t: no mention of 3.10 in: $OUT" ;; esac

t="AC-8 on Python 3.11 or later the check passes"
if [ "$real_ok" = 1 ]; then
  OUT="$(SHIPFLOOR_HOME="$home" bash "$src/scripts/shipfloor" doctor 2>&1)"
  n="$(printf '%s\n' "$OUT" | grep -c '^FAIL .*3\.11')"
  [ "$n" = 0 ] && pass "$t: no FAIL naming 3.11" || fail "$t: doctor fails the Python check: $OUT"
  printf '%s\n' "$OUT" | grep -Eq '^ok +.*[Pp]ython.*3\.[0-9]+' && pass "$t: an ok line names the Python version" || fail "$t: no 'ok ... python 3.x' line in: $OUT"
else
  pass "$t: skipped, this machine's Python is older than 3.11"
fi

finish
