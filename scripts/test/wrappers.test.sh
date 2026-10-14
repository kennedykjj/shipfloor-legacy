#!/usr/bin/env bash
# The thin Bash entry points, through real processes: a wrapper built from templates/py-wrapper.sh (lib/py.sh runs
# sf.py under `python -I`: the Python it picks, a PYTHONPATH or working directory that cannot shadow the package, no
# __pycache__ left, LF output), sf.py ending quietly on a closed pipe (board.sh items), and inbox-hook.sh, which never
# starts Python while the inbox is empty.
source "$(dirname "$0")/lib.sh"
ver() { tr -d '\r' | head -1; }

copy="$(plugin_copy)"; home="$(mktemp -d)"
SHIPFLOOR_HOME="$home" bash "$copy/scripts/shipfloor" install >/dev/null 2>&1 || fail "install of the plugin copy"
want="$("$FACTORY_PYTHON" -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import shipfloor_core; print(shipfloor_core.__version__)' "$copy/scripts" | tr -d '\r')"
[ -n "$want" ] && pass "the package declares a version ($want)" || fail "shipfloor_core declares no __version__"
cp "$copy/templates/py-wrapper.sh" "$copy/scripts/wrap.sh"; cp "$copy/templates/py-wrapper.sh" "$home/factory/wrap.sh"
wp="$copy/scripts/wrap.sh"; wi="$home/factory/wrap.sh"

# version from the plugin copy and from the installed factory, with or without FACTORY_PYTHON, from another directory
for w in "$wp" "$wi"; do
  out="$(bash "$w" version 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | ver)" = "$want" ] && pass "wrapper ${w%/wrap.sh}: version prints $want, exit 0" || fail "wrapper $w: exit $rc: $out"
done
out="$(env -u FACTORY_PYTHON -u SHIPFLOOR_PY bash "$wi" version 2>&1)"
[ "$(printf '%s' "$out" | ver)" = "$want" ] && pass "the wrapper finds python itself (FACTORY_PYTHON unset)" || fail "no FACTORY_PYTHON: $out"
out="$(cd "$(mktemp -d)" && bash "$wi" version 2>&1)"
[ "$(printf '%s' "$out" | ver)" = "$want" ] && pass "the wrapper runs from another working directory" || fail "other cwd: $out"
[ "$(bash "$wi" version 2>/dev/null | tr -cd '\r' | wc -c | tr -d ' ')" = 0 ] && pass "the version line is LF-terminated (no CR)" || fail "CR on stdout"
pyc="$(find "$home/factory" "$copy/scripts" \( -name __pycache__ -o -name "*.pyc" \) | head -3)"; [ -z "$pyc" ] && pass "sf.py leaves no __pycache__ behind" || fail "left: $pyc"

# lib/py.sh runs FACTORY_PYTHON, else SHIPFLOOR_PY, with -I, sf.py and the arguments (shipfloor doctor here)
rec="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\n' "$rec" > "$rec/py"; chmod +x "$rec/py"
FACTORY_PYTHON="$rec/py" SHIPFLOOR_HOME="$home" bash "$home/factory/shipfloor" doctor
[ "$(cat "$rec/calls")" = "-I $home/factory/sf.py cli doctor" ] && pass "shipfloor runs FACTORY_PYTHON -I sf.py cli doctor" || fail "FACTORY_PYTHON calls: $(cat "$rec/calls")"
: > "$rec/calls"; env -u FACTORY_PYTHON SHIPFLOOR_PY="$rec/py" bash "$wi" version
[ "$(cat "$rec/calls")" = "-I $home/factory/sf.py version" ] && pass "without FACTORY_PYTHON it runs SHIPFLOOR_PY" || fail "SHIPFLOOR_PY calls: $(cat "$rec/calls")"

# a fake shipfloor_core on PYTHONPATH or in the working directory is never imported (python -I)
fake="$(mktemp -d)"; mkdir -p "$fake/shipfloor_core" "$fake/cwd/shipfloor_core"
printf '__version__ = "FAKE-PYTHONPATH"\n' | tee "$fake/shipfloor_core/__init__.py" > "$fake/cwd/shipfloor_core/__init__.py"
printf 'raise SystemExit("the fake shipfloor_core was imported")\n' > "$fake/sitecustomize.py"
for w in "$wi" "$wp"; do
  out="$(PYTHONPATH="$fake" bash "$w" version 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | ver)" = "$want" ] && pass "PYTHONPATH with a fake package does not shadow ${w%/wrap.sh}" || fail "PYTHONPATH fake ($w): exit $rc: $out"
done
out="$(cd "$fake/cwd" && bash "$wi" version 2>&1)"
[ "$(printf '%s' "$out" | ver)" = "$want" ] && pass "a fake package in the working directory does not shadow it" || fail "cwd fake: $out"

# sf.py ends quietly when the reader of its stdout goes away (the dispatcher's health record does that)
big="$(mktemp -d)/big"; seq 1 20000 | sed 's/.*/&\tCoding\tPVTI_&/' > "$big"
FACTORY_BOARD_SNAPSHOT="$big" bash "$FACTORY_DIR/board.sh" items 2>"$big.err" | head -1 >/dev/null; rc=${PIPESTATUS[0]}
[ ! -s "$big.err" ] && pass "a closed reader: no traceback" || fail "stderr: $(head -3 "$big.err")"
{ [ "$rc" = 141 ] || [ "$rc" = 0 ]; } && pass "a closed reader: exit 141 (or 0 when it finished first)" || fail "exit $rc"

# inbox-hook.sh: no lock, no inbox, an empty one or a missing lock folder → exit 0, silent, Python never started
hook="$FACTORY_DIR/inbox-hook.sh"; lock="$(mktemp -d)"; : > "$rec/calls"
for l in "" "$lock" "$lock/empty" "$rec/no-such-lock"; do
  [ "$l" = "$lock/empty" ] && { l="$lock"; : > "$lock/inbox"; }
  out="$(env -u SHIPFLOOR_PY SHIPFLOOR_RUN_LOCK="$l" FACTORY_PYTHON="$rec/py" bash "$hook" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$rec/calls" ] && pass "inbox-hook, lock '${l:-none}' $( [ -e "$l/inbox" ] && echo '(empty inbox)'): exit 0, silent, no Python" \
    || fail "inbox-hook with lock '$l': exit $rc, out '$out', python: $(cat "$rec/calls")"
done
echo hello > "$lock/inbox"; env -u SHIPFLOOR_PY SHIPFLOOR_RUN_LOCK="$lock" FACTORY_PYTHON="$rec/py" bash "$hook" >/dev/null 2>&1
assert_contains "$(cat "$rec/calls")" "inbox_hook.py"
finish
