#!/usr/bin/env bash
# shipfloor-config.sh answers `machine ...` from anywhere: the installer asks it for dispatcher.every_min
# outside any project, with only SHIPFLOOR_HOME to go by.
source "$(dirname "$0")/lib.sh"

CFG="$FACTORY_DIR/shipfloor-config.sh"
H="$(mktemp -d)"; OUT="$(mktemp -d)"   # OUT: a directory that is in no registered project
ask() { (cd "$OUT" && SHIPFLOOR_HOME="$H" bash "$CFG" machine values dispatcher.every_min 2>&1 | tr '\0' ' '); }

want="3 "; got="$(ask)"
[ "$got" = "$want" ] && pass "no config.yml: prints 3" || fail "no config.yml printed: $got"

printf 'dispatcher: {every_min: 10}\n' > "$H/config.yml"
got="$(ask)"
[ "$got" = "10 " ] && pass "outside a project, config.yml every_min 10 prints 10" || fail "every_min 10 printed: $got"
(cd "$OUT" && SHIPFLOOR_HOME="$H" bash "$CFG" machine values dispatcher.every_min >/dev/null 2>&1)
[ $? -eq 0 ] && pass "and exits 0" || fail "exit was not 0"

out="$(cd "$OUT" && SHIPFLOOR_HOME="$H" bash "$CFG" machine set dispatcher.every_min 5 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "machine set still refuses dispatcher.every_min" || fail "machine set accepted dispatcher.every_min: $out"
grep -q 'every_min: 10' "$H/config.yml" && pass "the file is unchanged by the refused set" || fail "config.yml changed: $(cat "$H/config.yml")"

# The installer without -EveryMin: -DryRun writes nothing; it reads the INSTALLED copy in the real home,
# so only the shape of the answer is asserted.
if command -v powershell >/dev/null 2>&1; then
  PS1="$FACTORY_DIR/../installer/install-dispatcher.ps1"
  if command -v cygpath >/dev/null 2>&1; then PS1="$(cygpath -w "$PS1")"; fi
  dry="$(powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1" -DryRun 2>&1)"
  case "$dry" in
    *"ShipfloorDispatcher: every 1 minutes"*|*"ShipfloorDispatcher: every 3 minutes"*|*"ShipfloorDispatcher: every 5 minutes"*|*"ShipfloorDispatcher: every 10 minutes"*)
      pass "installer -DryRun without -EveryMin names a pace" ;;
    *) fail "installer -DryRun printed: $dry" ;;
  esac
fi

finish
