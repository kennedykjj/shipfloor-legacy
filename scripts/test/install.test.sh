#!/usr/bin/env bash
# suite: integration
# shipfloor install and doctor's view of the installed copy. The behavior is in py/install_copy.py, in process
# (shipfloor_core/cli.py: renames, counts, kills and refusals, the source check, .source/.origin, doctor); here the
# wrapper's contract through a real process: the real plugin installed into a temp SHIPFLOOR_HOME, what goes to stdout
# and stderr, and the usage error.
source "$(dirname "$0")/lib.sh"
py_suite install_copy

copy="$(plugin_copy)"; home="$(mktemp -d)"
out="$(SHIPFLOOR_HOME="$home" bash "$copy/scripts/shipfloor" install 2>"$home.err")"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$home.err" ] && pass "install of the real plugin: exit 0, nothing on stderr" || fail "install: exit $rc: $out $(cat "$home.err")"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "installed $copy → $home/factory: 0 replaced, $(find "$copy/scripts" "$copy/templates" -type f | wc -l | tr -d ' ') added, 0 removed" ] \
  && pass "stdout: the installed line counts every file added" || fail "stdout: $out"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = "next: shipfloor add <repo>; then bash \"$copy/installer/install-dispatcher.sh\"" ] \
  && pass "stdout: the next: line" || fail "stdout: $out"
[ -f "$home/factory/sf.py" ] && [ -f "$home/factory/shipfloor_core/__init__.py" ] && [ -f "$home/factory/templates/py-wrapper.sh" ] \
  && [ "$(cat "$home/factory/.source")" = "$copy" ] && pass "the package, the templates and .source are in place" || fail "installed copy: $(ls "$home/factory")"
[ -z "$(find "$home/factory" -name __pycache__ -o -name '*.pyc' -o -path '*/test/*' | head -3)" ] && pass "no test/ or __pycache__ in the copy" || fail "copied: $(find "$home/factory" -name __pycache__ | head -3)"

out="$(SHIPFLOOR_HOME="$home" bash "$copy/scripts/shipfloor" install --bogus 2>"$home.err")"; rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && [ "$(cat "$home.err")" = "shipfloor: usage: shipfloor install [--force]" ] \
  && pass "install --bogus: exit 2, the usage line on stderr only" || fail "install --bogus: exit $rc: $out $(cat "$home.err")"
finish
