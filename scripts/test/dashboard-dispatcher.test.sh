#!/usr/bin/env bash
# Settings: how often the dispatcher looks for work (dispatcher.every_min). Every server here runs with
# SHIPFLOOR_SCHEDULER set to a stub (or "none"): a test never touches the real ShipfloorDispatcher task.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
C="$(mktemp -d)"; PIDS=""; SLEEPER=""
trap 'kill $PIDS $SLEEPER 2>/dev/null' EXIT
BASH_N="$(nat "$(command -v bash)")"

# a scheduler stub that records the arguments it gets (exit 0), and one that fails on purpose
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$(nat "$C")/stub-ok" > "$C/ok-stub.sh"
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\necho "trying the task"\necho "boom: access denied"\nexit 1\n' "$(nat "$C")/stub-bad" > "$C/bad-stub.sh"
# SHIPFLOOR_SCHEDULER is split like a shell command line (shlex) and run as an argument list, the minutes
# appended last: each part is quoted here so a path with a space (Program Files, a temp dir) stays one word.
OK_CMD="\"$BASH_N\" \"$(nat "$C")/ok-stub.sh\""; BAD_CMD="\"$BASH_N\" \"$(nat "$C")/bad-stub.sh\""

# fresh_home: a home with one project and no config.yml
fresh_home() {
  H="$(mktemp -d)"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$H/logs"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
  rm -f "$C/stub-ok" "$C/stub-bad"
}
# start_dash <tag> <scheduler>: a dashboard on $H with SHIPFLOOR_SCHEDULER=<scheduler>; sets base and tok
start_dash() {
  SHIPFLOOR_SCHEDULER="$2" SHIPFLOOR_BASH="$BASH_N" FAKE_GH_NO_JQ=1 FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_DIR="$C" \
    $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$C/out-$1" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do grep -qs 'http://' "$C/out-$1" && break; sleep 0.1; done
  url="$(grep -o 'http://[^ ]*' "$C/out-$1")"; base="${url%%/?t=*}"; tok="${url##*t=}"
}
post() { curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H "X-Shipfloor-Token: $tok" -d "$1" "$base/api/settings/machine"; }
# jget <json> <python expr on d>
jget() { printf '%s' "$1" | $PY -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>&1; }
disp() { curl -s -H "X-Shipfloor-Token: $tok" "$base/api/settings" | $PY -c "import json,sys; d=json.load(sys.stdin)['dispatcher']; print($1)" 2>/dev/null || echo "no dispatcher in /api/settings"; }
# page_has <text> <why>: the page (never dumped on a miss: it is long) carries the text
page_has() { if curl -s "$base/" | grep -qF -- "$1"; then pass "$2: the page carries '$1'"; else fail "$2: the page does not carry '$1'"; fi; }
cfg() { $PY -I -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print((d.get("dispatcher") or {}).get(sys.argv[2]))' "$(nat "$H/config.yml")" "$1" 2>&1; }

# --- AC-2: no dispatcher.every_min in config.yml: 3 minutes, and exactly 1, 3, 5 and 10 on offer
fresh_home; start_dash a "$OK_CMD"
got="$(disp 'd["every_min"], d["choices"]')"
[ "$got" = "3 [1, 3, 5, 10]" ] && pass "AC-2 no every_min in config.yml shows 3 and offers exactly 1, 3, 5, 10" || fail "AC-2 settings dispatcher was: $got (want '3 [1, 3, 5, 10]')"
got="$(disp 'd["can_set"], d["why"]')"
[ "$got" = "True None" ] && pass "AC-2 a machine with the task can set the pace" || fail "AC-2 can_set/why was: $got (want 'True None')"
page_has "Looks for work every" "AC-2"
page_has '${every(n)}' "AC-2"  # each choice under its own plural form, the page's language's (#122)
[ "$(en_msg disp.every_n)" = "{n, plural, one {# minute} other {# minutes}}" ] && pass "AC-2 1 minute, 3 minutes, 5 minutes, 10 minutes" || fail "AC-2 disp.every_n is: $(en_msg disp.every_n)"

# --- AC-1: pick 5 and save: the task is re-registered with 5, config.yml holds 5, the settings answer 5
resp="$(post '{"dispatcher":{"every_min":5}}')"; code="${resp##*$'\n'}"
[ "$code" = 200 ] && pass "AC-1 saving 5 answers 200" || fail "AC-1 saving 5 answered $code: $resp"
[ "$(cat "$C/stub-ok" 2>/dev/null | tr -d '\r')" = "5" ] && pass "AC-1 the scheduler stub received 5" || fail "AC-1 the scheduler stub received: '$(cat "$C/stub-ok" 2>/dev/null)' (want '5')"
[ "$(cfg every_min)" = "5" ] && pass "AC-1 config.yml holds dispatcher.every_min: 5" || fail "AC-1 config.yml dispatcher.every_min is: $(cfg every_min)"
[ "$(disp 'd["every_min"]')" = "5" ] && pass "AC-1 /api/settings answers 5" || fail "AC-1 /api/settings dispatcher.every_min is: $(disp 'd["every_min"]')"
[ "$(SHIPFLOOR_HOME="$H" bash "$FACTORY_DIR/shipfloor-config.sh" machine values dispatcher.every_min 2>&1 | tr '\0' ' ')" = "5 " ] && pass "AC-1 machine values dispatcher.every_min prints 5" || fail "AC-1 machine values dispatcher.every_min printed: $(SHIPFLOOR_HOME="$H" bash "$FACTORY_DIR/shipfloor-config.sh" machine values dispatcher.every_min 2>&1 | tr '\0' ' ')"
# a value outside the four is refused before anything runs
rm -f "$C/stub-ok"
resp="$(post '{"dispatcher":{"every_min":7}}')"; code="${resp##*$'\n'}"
[ "$code" = 400 ] && [ ! -e "$C/stub-ok" ] && pass "AC-1 7 minutes is refused and the scheduler is not called" || fail "AC-1 7 minutes answered $code, scheduler calls: $(cat "$C/stub-ok" 2>/dev/null)"
# the installer: -DryRun prints the pace and registers nothing (only where powershell exists; never without -DryRun)
INST="$FACTORY_DIR/../installer/install-dispatcher.ps1"
if command -v powershell >/dev/null 2>&1; then
  if grep -q 'DryRun' "$INST" && grep -q 'EveryMin' "$INST"; then
    out="$(powershell -NoProfile -ExecutionPolicy Bypass -File "$(nat "$INST")" -DryRun -EveryMin 5 2>&1 | tr -d '\r')"
    assert_contains "$out" "ShipfloorDispatcher: every 5 minutes"
  else
    fail "AC-1 install-dispatcher.ps1 has no -DryRun / -EveryMin (not run: it would register the real task)"
  fi
else
  pass "AC-1 no powershell here: installer -DryRun check skipped"
fi

# --- AC-3: a cycle that is running is not touched by a save; the new pace is what the task gets
fresh_home; start_dash b "$OK_CMD"
sleep 300 & SLEEPER=$!
echo "$SLEEPER" > "$H/dispatch.pid"
resp="$(post '{"dispatcher":{"every_min":10}}')"; code="${resp##*$'\n'}"
[ "$code" = 200 ] && [ "$(cat "$C/stub-ok" 2>/dev/null | tr -d '\r')" = "10" ] && pass "AC-3 the save re-registers the task with 10" || fail "AC-3 save answered $code, scheduler got '$(cat "$C/stub-ok" 2>/dev/null)' (want 200 and '10')"
kill -0 "$SLEEPER" 2>/dev/null && pass "AC-3 the running cycle's process survived the save" || fail "AC-3 the running cycle's process was killed"
[ "$(cat "$H/dispatch.pid" 2>/dev/null | tr -d '\r')" = "$SLEEPER" ] && pass "AC-3 dispatch.pid still names the running cycle" || fail "AC-3 dispatch.pid changed or vanished"
STOPRE='Stop-ScheduledTask|Stop-Process|taskkill|Stop-Service|Stop-Job'
printf 'Stop-ScheduledTask -TaskName x\n' > "$C/inst-bad.ps1"
grep -Eiq "$STOPRE" "$C/inst-bad.ps1" && pass "AC-3 the stop/kill check does match a file that stops the task" || fail "AC-3 the stop/kill check is vacuous: it missed Stop-ScheduledTask"
if [ ! -f "$INST" ]; then fail "AC-3 the installer $INST does not exist"
elif grep -Eiq "$STOPRE" "$INST"; then fail "AC-3 the installer stops or kills something"; else pass "AC-3 the installer has no stop or kill"; fi
kill "$SLEEPER" 2>/dev/null; SLEEPER=""

# --- AC-4: re-registering fails: the reason comes back as 409, config.yml and the pace stay
fresh_home; printf 'pool: 6\ndispatcher:\n  every_min: 3\n' > "$H/config.yml"; cp "$H/config.yml" "$C/config.before"
start_dash c "$BAD_CMD"
resp="$(post '{"dispatcher":{"every_min":10},"pool":7}')"; code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
[ "$code" = 409 ] && pass "AC-4 a failing scheduler answers 409" || fail "AC-4 a failing scheduler answered $code: $resp"
[ "$(jget "$body" 'd.get("error")')" = "boom: access denied" ] && pass "AC-4 the reason is the scheduler's last output line" || fail "AC-4 the reason was: $(jget "$body" 'd.get("error")') (want 'boom: access denied')"
cmp -s "$H/config.yml" "$C/config.before" && pass "AC-4 config.yml is byte-identical (the other limits are not saved either)" || fail "AC-4 config.yml changed after a failed save: $(cat "$H/config.yml")"
[ "$(disp 'd["every_min"]')" = "3" ] && pass "AC-4 the settings still answer 3" || fail "AC-4 the settings answer: $(disp 'd["every_min"]')"
[ "$(cat "$C/stub-bad" 2>/dev/null | tr -d '\r')" = "10" ] && pass "AC-4 the scheduler was asked for 10" || fail "AC-4 the scheduler got: '$(cat "$C/stub-bad" 2>/dev/null)' (want '10')"

# --- AC-6: next cycle = last cycle's start (at - took_s) + the interval; the page words it and the overdue case
fresh_home; printf 'dispatcher:\n  every_min: 5\n' > "$H/config.yml"
printf '{"ts":"2026-10-11T10:00:10+00:00","cycle":{"s":10,"exit":0,"overlap":false},"paused":false,"idle":[],"over":[]}\n' > "$H/logs/health-2026-10.jsonl"
start_dash d "$OK_CMD"
got="$(curl -s -H "X-Shipfloor-Token: $tok" "$base/api/settings" | $PY -c 'import json,sys; from datetime import datetime,timezone; n=json.load(sys.stdin)["cycle"].get("next_at"); print(datetime.fromisoformat(n).astimezone(timezone.utc).isoformat() if n else None)' 2>/dev/null)"
[ "$got" = "2026-10-11T10:05:00+00:00" ] && pass "AC-6 cycle.next_at is the cycle's start plus 5 min" || fail "AC-6 cycle.next_at was: $got (want 2026-10-11T10:05:00+00:00)"
page_has "next cycle in" "AC-6"
page_has "next cycle overdue" "AC-6"

# --- AC-8: no scheduled task on this machine: the control is off with a reason, a save is a 409 and changes nothing
fresh_home; printf 'pool: 6\n' > "$H/config.yml"; cp "$H/config.yml" "$C/config.before"
start_dash e none
got="$(disp 'd["can_set"], bool(d["why"])')"
[ "$got" = "False True" ] && pass "AC-8 without the task can_set is false and there is a reason" || fail "AC-8 can_set/why was: $got (want 'False True')"
resp="$(post '{"dispatcher":{"every_min":5}}')"; code="${resp##*$'\n'}"
[ "$code" = 409 ] && pass "AC-8 a save without the task answers 409" || fail "AC-8 a save without the task answered $code: $resp"
cmp -s "$H/config.yml" "$C/config.before" && pass "AC-8 config.yml is untouched" || fail "AC-8 config.yml changed: $(cat "$H/config.yml")"
page_has "Windows only" "AC-8"
finish
