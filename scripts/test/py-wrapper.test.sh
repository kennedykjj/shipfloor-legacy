#!/usr/bin/env bash
# A wrapper built from templates/py-wrapper.sh (it sources lib/py.sh and runs sf.py under `python -I`) (#162):
#   AC-1  `version` prints the package version and exits 0, from a plugin copy and from an installed factory
#   AC-2  a PYTHONPATH (or a working directory) holding a fake shipfloor_core does not shadow the installed one
source "$(dirname "$0")/lib.sh"

copy="$(plugin_copy)"
home="$(mktemp -d)"
SHIPFLOOR_HOME="$home" bash "$copy/scripts/shipfloor" install >/dev/null 2>&1
inst="$home/factory"

want="$("$FACTORY_PYTHON" -I -c 'import re,sys; m = re.search(r"__version__\s*=\s*[\"\x27]([^\"\x27]+)", open(sys.argv[1], encoding="utf-8").read()); print(m.group(1) if m else "")' "$copy/scripts/shipfloor_core/__init__.py" 2>/dev/null | tr -d '\r')"
[ -n "$want" ] && pass "the package declares a version ($want)" || fail "shipfloor_core/__init__.py declares no __version__"

mk_wrapper() {  # mk_wrapper <dir>: the template, as a script beside lib/py.sh; prints its path
  cp "$copy/templates/py-wrapper.sh" "$1/wrap.sh" 2>/dev/null || return 1
  echo "$1/wrap.sh"
}
wp="$(mk_wrapper "$copy/scripts")" || { wp="$copy/scripts/wrap.sh"; fail "templates/py-wrapper.sh does not exist"; }
wi="$(mk_wrapper "$inst")" || { wi="$inst/wrap.sh"; fail "templates/py-wrapper.sh is not installed"; }

# ---- AC-1
t="AC-1 a wrapper from the template runs sf.py version (plugin copy)"
out="$(bash "$wp" version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "$t: exits 0" || fail "$t: exit $rc: $out"
[ -n "$want" ] && [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ] && pass "$t: prints $want" || fail "$t: prints '$out', want '$want'"

t="AC-1 the same wrapper in an installed factory"
out="$(bash "$wi" version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "$t: exits 0" || fail "$t: exit $rc: $out"
[ -n "$want" ] && [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ] && pass "$t: prints $want" || fail "$t: prints '$out', want '$want'"
[ -f "$inst/sf.py" ] && pass "$t: sf.py is installed" || fail "$t: sf.py is not in the installed copy"

t="AC-1 the wrapper finds python itself (FACTORY_PYTHON unset)"
out="$(env -u FACTORY_PYTHON -u SHIPFLOOR_PY bash "$wi" version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$want" ] && [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ] && pass "$t" || fail "$t: exit $rc, prints '$out', want '$want'"

t="AC-1 the wrapper runs from another working directory"
out="$(cd "$(mktemp -d)" && bash "$wi" version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$want" ] && [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ] && pass "$t" || fail "$t: exit $rc, prints '$out', want '$want'"

t="AC-1 the version line is LF-terminated (no CR on stdout)"
crs="$(bash "$wi" version 2>/dev/null | tr -cd '\r' | wc -c | tr -d ' ')"
[ -n "$(bash "$wi" version 2>/dev/null)" ] && [ "$crs" = 0 ] && pass "$t" || fail "$t: CRs: $crs"

# ---- AC-2
fake="$(mktemp -d)"; mkdir -p "$fake/shipfloor_core"
printf '__version__ = "FAKE-PYTHONPATH"\n' > "$fake/shipfloor_core/__init__.py"
printf 'raise SystemExit("the fake shipfloor_core was imported")\n' > "$fake/sitecustomize.py"

t="AC-2 PYTHONPATH with a fake shipfloor_core does not shadow the installed one"
out="$(PYTHONPATH="$fake" bash "$wi" version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "$t: exits 0" || fail "$t: exit $rc: $out"
case "$out" in *FAKE-PYTHONPATH*|*"fake shipfloor_core"*) fail "$t: the fake package was loaded: $out" ;; *) pass "$t: the fake is not loaded" ;; esac
[ -n "$want" ] && [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ] && pass "$t: the installed version $want is printed" || fail "$t: prints '$out', want '$want'"

t="AC-2 a fake shipfloor_core in the working directory does not shadow it either"
mkdir -p "$fake/cwd" && cp -r "$fake/shipfloor_core" "$fake/cwd/shipfloor_core"
out="$(cd "$fake/cwd" && bash "$wi" version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$want" ] && [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ] && pass "$t" || fail "$t: exit $rc, prints '$out', want '$want'"

t="AC-2 from the plugin copy too"
out="$(PYTHONPATH="$fake" bash "$wp" version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$want" ] && [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ] && pass "$t" || fail "$t: exit $rc, prints '$out', want '$want'"

finish
