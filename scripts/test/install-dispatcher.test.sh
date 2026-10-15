#!/usr/bin/env bash
# suite: integration
# installer/install-dispatcher.sh registers the dispatcher on Linux (systemd user timer, else crontab) and
# macOS (launchd user agent), removes it with --uninstall and reports it with --status.
# Nothing here touches the machine's timers: a temp HOME and SHIPFLOOR_HOME, and stand-ins for systemctl,
# loginctl, crontab, launchctl and uname first on PATH. The stand-ins record their arguments; their state
# (the crontab table, whether the timer is enabled, lingering) lives in files under $SF_ST.
source "$(dirname "$0")/lib.sh"
INST="$(cd "$FACTORY_DIR/.." && pwd)/installer/install-dispatcher.sh"
unset XDG_CONFIG_HOME
ROOT="$(mktemp -d)"; STUBS="$ROOT/stubs"; FAKEBIN="$ROOT/fakebin"; mkdir -p "$STUBS" "$FAKEBIN"
ORIG_PATH="$PATH"; export SF_REAL_UNAME="$(command -v uname)"
MARK='# shipfloor-dispatcher'

stub() {  # stub <name>: the script on stdin becomes an executable on the stand-in PATH
  cat > "$STUBS/$1"; chmod +x "$STUBS/$1"
}
stub uname <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -s ]; then echo "${SF_UNAME:-Linux}"; else exec "$SF_REAL_UNAME" "$@"; fi
EOF
stub systemctl <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SF_ST/systemctl.log"
verb=; for a in "$@"; do case "$a" in -*) ;; *) verb="$a"; break ;; esac; done
case "$verb" in
  show-environment) [ -e "$SF_ST/no-systemd" ] && exit 1; echo "PATH=/usr/bin" ;;
  is-enabled|is-active) [ -e "$SF_ST/timer-enabled" ] && { echo enabled; exit 0; }; echo disabled; exit 1 ;;
  enable) : > "$SF_ST/timer-enabled" ;;
  disable) rm -f "$SF_ST/timer-enabled" ;;
esac
exit 0
EOF
stub loginctl <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SF_ST/loginctl.log"
v=no; [ -e "$SF_ST/linger" ] && v=yes
case "$*" in *--value*) echo "$v" ;; *) echo "Linger=$v" ;; esac
exit 0
EOF
stub crontab <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SF_ST/crontab.log"
case "${1:-}" in
  -l) if [ -f "$SF_ST/crontab.table" ]; then cat "$SF_ST/crontab.table"; exit 0; fi; echo "no crontab for ${USER:-user}" >&2; exit 1 ;;
  -) cat > "$SF_ST/crontab.table" ;;
  -r) rm -f "$SF_ST/crontab.table" ;;
  *) cp "$1" "$SF_ST/crontab.table" ;;
esac
exit 0
EOF
stub launchctl <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SF_ST/launchctl.log"
case "${1:-}" in
  bootstrap|load) : > "$SF_ST/agent-loaded" ;;
  bootout|unload|remove) rm -f "$SF_ST/agent-loaded" ;;
  print|list|print-disabled) [ -e "$SF_ST/agent-loaded" ] || exit 1 ;;
esac
exit 0
EOF
for t in claude gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$t"; chmod +x "$FAKEBIN/$t"; done

fresh() {  # fresh: a new HOME, SHIPFLOOR_HOME with an installed factory, empty stand-in state; Linux with systemd
  T="$(mktemp -d)"; export HOME="$T/home" SHIPFLOOR_HOME="$T/sf" SF_ST="$T/st" SF_UNAME=Linux
  mkdir -p "$HOME" "$SF_ST" "$SHIPFLOOR_HOME/factory" "$SHIPFLOOR_HOME/logs"
  cp -r "$FACTORY_DIR/." "$SHIPFLOOR_HOME/factory/"; rm -rf "$SHIPFLOOR_HOME/factory/test"
  export PATH="$STUBS:$FAKEBIN:$ORIG_PATH"
  UNITS="$HOME/.config/systemd/user"; SVC="$UNITS/shipfloor-dispatcher.service"; TMR="$UNITS/shipfloor-dispatcher.timer"
  PLIST="$HOME/Library/LaunchAgents/com.shipfloor.dispatcher.plist"; TABLE="$SF_ST/crontab.table"
}
inst() { bash "$INST" "$@"; }
run() {  # run <args>: out and rc of the installer
  out="$(inst "$@" 2>&1)"; rc=$?
}
count() { local n; n="$(grep -c -- "$2" "$1" 2>/dev/null)"; echo "${n:-0}"; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
dispatcher_lines() { grep -c -- "$MARK" "$TABLE" 2>/dev/null || true; }
others() { grep -v -- "$MARK" "$TABLE" 2>/dev/null; }
OTHER_TABLE=$'MAILTO=me@example.com\n0 1 * * * /usr/bin/backup --all\n# a comment\n*/15 * * * * /opt/other/job.sh\n'

# --- AC-1: Linux with a systemd user session -> a user timer and service, lingering reported
fresh; run
[ "$rc" -eq 0 ] && pass "AC-1 install on systemd exits 0" || fail "AC-1 install on Linux with systemd exited $rc (want 0, installer/install-dispatcher.sh missing or failing): $out"
[ -f "$SVC" ] && [ -f "$TMR" ] && pass "AC-1 user service and timer written under ~/.config/systemd/user" || fail "AC-1 no shipfloor-dispatcher.service/.timer in $UNITS"
assert_contains "$(cat "$TMR" 2>/dev/null)" "OnCalendar=*:0/3"
assert_contains "$(cat "$SVC" 2>/dev/null)" "run-dispatcher.sh"
assert_contains "$(cat "$SVC" 2>/dev/null)" "$SHIPFLOOR_HOME/factory/run-dispatcher.sh"
assert_contains "$(cat "$SVC" 2>/dev/null)" " -l "
assert_contains "$(cat "$SVC" 2>/dev/null)" "SHIPFLOOR_HOME=$SHIPFLOOR_HOME"
assert_contains "$(cat "$SVC" 2>/dev/null)" "Type=oneshot"
assert_contains "$(cat "$SVC" 2>/dev/null)" "KillMode=process"
assert_contains "$(cat "$SF_ST/systemctl.log" 2>/dev/null)" "daemon-reload"
assert_contains "$(cat "$SF_ST/systemctl.log" 2>/dev/null)" "enable --now shipfloor-dispatcher.timer"
case "$(grep -v '^ *#' "$SF_ST/systemctl.log" 2>/dev/null)" in *"--user"*) pass "AC-1 systemctl is always the user instance" ;; *) fail "AC-1 systemctl was not called with --user" ;; esac
lo="$(lower "$out")"
case "$lo" in *linger*) pass "AC-1 output says whether lingering is on" ;; *) fail "AC-1 output does not mention lingering: $out" ;; esac
case "$lo" in *"logout"*|*"log out"*|*"logs out"*) pass "AC-1 lingering off: says the dispatcher stops at logout" ;; *) fail "AC-1 lingering off but no word on stopping at logout: $out" ;; esac
assert_contains "$out" "loginctl enable-linger"
[ "$(cat "$SHIPFLOOR_HOME/dispatcher.path" 2>/dev/null)" = "$PATH" ] && pass "AC-1 dispatcher.path holds the installing PATH and nothing else" || fail "AC-1 $SHIPFLOOR_HOME/dispatcher.path is not exactly PATH: $(cat "$SHIPFLOOR_HOME/dispatcher.path" 2>/dev/null)"
[ "$(cat "$SHIPFLOOR_HOME/dispatcher.wake" 2>/dev/null)" = "$(printf '%s\n' systemctl --user start --no-block shipfloor-dispatcher.service)" ] && pass "wake: systemd: a run that ends starts the cycle's service, without waiting" || fail "wake: systemd: dispatcher.wake is: $(cat "$SHIPFLOOR_HOME/dispatcher.wake" 2>/dev/null)"

fresh; : > "$SF_ST/linger"; run
case "$(lower "$out")" in *linger*) pass "AC-1 lingering on is reported" ;; *) fail "AC-1 lingering on is not mentioned: $out" ;; esac
case "$out" in *enable-linger*) fail "AC-1 lingering is on but the output still says how to enable it: $out" ;; *) pass "AC-1 lingering on: no instruction to enable it" ;; esac

# the pace: --every-min, else dispatcher.every_min of the machine config, else 3
fresh; printf 'dispatcher: {every_min: 5}\n' > "$SHIPFLOOR_HOME/config.yml"; run
assert_contains "$(cat "$TMR" 2>/dev/null)" "OnCalendar=*:0/5"
fresh; printf 'dispatcher: {every_min: 5}\n' > "$SHIPFLOOR_HOME/config.yml"; run --every-min 10
assert_contains "$(cat "$TMR" 2>/dev/null)" "OnCalendar=*:0/10"
fresh; run --every-min 7
[ "$rc" -eq 2 ] && pass "AC-1 --every-min 7 exits 2" || fail "AC-1 --every-min 7 exited $rc (want 2): $out"
[ ! -e "$TMR" ] && [ ! -e "$SF_ST/systemctl.log" ] && pass "AC-1 a refused pace registers nothing" || fail "AC-1 --every-min 7 still registered something"
# 30 seconds (0.5): systemd fires on the half minute with a 1 s accuracy (the default 1 min would blur it), launchd
# every 30 s; cron cannot go below a minute and refuses it (exit 2) instead of rounding; the minute paces' timers are as before
fresh; run --every-min 0.5
[ "$rc" -eq 0 ] && pass "30s: --every-min 0.5 on systemd exits 0" || fail "30s: --every-min 0.5 on systemd exited $rc: $out"
tm="$(cat "$TMR" 2>/dev/null)"
case "$tm" in *"OnCalendar=*:*:0/30"*"AccuracySec=1s"*) pass "30s: the timer fires every 30 s with AccuracySec=1s" ;; *) fail "30s: timer: $tm" ;; esac
assert_contains "$out" "every 30 seconds"
run --status
assert_contains "$out" "pace: every 30 seconds"
fresh; printf 'dispatcher: {every_min: 0.5}\n' > "$SHIPFLOOR_HOME/config.yml"; run
assert_contains "$(cat "$TMR" 2>/dev/null)" "OnCalendar=*:*:0/30"
fresh; run --every-min 3
case "$(cat "$TMR" 2>/dev/null)" in *AccuracySec*) fail "30s: a minute pace's timer gained AccuracySec" ;; *) pass "30s: a minute pace's timer is unchanged (no AccuracySec)" ;; esac
run --status
assert_contains "$out" "pace: every 180 seconds"
fresh; : > "$SF_ST/no-systemd"; printf '%s' "$OTHER_TABLE" > "$TABLE"; run --every-min 0.5
[ "$rc" -eq 2 ] && pass "30s: cron refuses 0.5 with exit 2" || fail "30s: cron with 0.5 exited $rc (want 2): $out"
assert_contains "$out" "cron cannot run the dispatcher more often than once a minute"
[ "$(dispatcher_lines)" = 0 ] && [ "$(others)" = "$(printf '%s' "$OTHER_TABLE")" ] && [ ! -e "$SHIPFLOOR_HOME/dispatcher.path" ] && pass "30s: the refusal writes nothing" || fail "30s: cron refusal still wrote: $(cat "$TABLE")"
fresh; : > "$SF_ST/no-systemd"; printf 'dispatcher: {every_min: 0.5}\n' > "$SHIPFLOOR_HOME/config.yml"; run --dry-run
[ "$rc" -eq 2 ] && pass "30s: 0.5 from config.yml on cron is refused too, even in a dry run" || fail "30s: cron + config 0.5 exited $rc: $out"
fresh; : > "$SF_ST/no-systemd"; run --every-min 1; run --status
assert_contains "$out" "pace: every 60 seconds"
fresh; SF_UNAME=Darwin run --every-min 0.5
assert_contains "$(cat "$PLIST" 2>/dev/null)" "<key>StartInterval</key><integer>30</integer>"
SF_UNAME=Darwin run --status
assert_contains "$out" "pace: every 30 seconds"
run --kind sysv
[ "$rc" -eq 2 ] && pass "AC-1 --kind sysv exits 2" || fail "AC-1 --kind sysv exited $rc (want 2): $out"

# requirements and refusals
fresh; rm -f "$SHIPFLOOR_HOME/factory/run-dispatcher.sh"; run
[ "$rc" -eq 1 ] && pass "AC-1 without an installed factory it exits 1" || fail "AC-1 without run-dispatcher.sh it exited $rc (want 1): $out"
assert_contains "$out" "shipfloor install"
fresh; SF_UNAME=MINGW64_NT-10.0 run
[ "$rc" -ne 0 ] && pass "AC-1 Git Bash is refused" || fail "AC-1 Git Bash was not refused"
assert_contains "$out" "install-dispatcher.ps1"
[ ! -e "$SF_ST/systemctl.log" ] && [ ! -e "$SF_ST/crontab.log" ] && pass "AC-1 a refusal touches no scheduler" || fail "AC-1 Git Bash refusal still called a scheduler"
SF_UNAME=MINGW64_NT-10.0 run --status
[ "$rc" -eq 2 ] && [ -z "$out" ] && pass "AC-1 --status on Windows exits 2 and prints nothing" || fail "AC-1 --status on Windows: exit $rc, output '$out' (want 2 and nothing)"

# --dry-run and --status change nothing
fresh; run --dry-run --kind cron --every-min 5
[ "$rc" -eq 0 ] && pass "AC-1 --dry-run exits 0" || fail "AC-1 --dry-run exited $rc (want 0): $out"
assert_contains "$out" "cron"
assert_contains "$out" "5"
[ ! -e "$TABLE" ] && [ ! -e "$SHIPFLOOR_HOME/dispatcher.path" ] && pass "AC-1 --dry-run changes nothing" || fail "AC-1 --dry-run wrote a crontab or dispatcher.path"
run --status
[ "$rc" -eq 1 ] && pass "AC-1 --status with nothing registered exits 1" || fail "AC-1 --status with nothing registered exited $rc (want 1): $out"
assert_contains "$out" "not registered"
assert_contains "$out" "install-dispatcher.sh"
fresh; run >/dev/null; run --status
[ "$rc" -eq 0 ] && pass "AC-1 --status after install exits 0" || fail "AC-1 --status after install exited $rc (want 0): $out"
assert_contains "$out" "registered: systemd"

# --- AC-2: Linux without a usable systemd user session -> exactly one crontab line, the others untouched
fresh; : > "$SF_ST/no-systemd"; printf '%s' "$OTHER_TABLE" > "$TABLE"; run
[ "$rc" -eq 0 ] && pass "AC-2 install on cron exits 0" || fail "AC-2 install without systemd exited $rc (want 0): $out"
[ "$(dispatcher_lines)" = 1 ] && pass "AC-2 exactly one dispatcher line" || fail "AC-2 dispatcher lines in the crontab: $(dispatcher_lines)"
[ "$(others)" = "$(printf '%s' "$OTHER_TABLE")" ] && pass "AC-2 every other crontab line is unchanged" || fail "AC-2 the other crontab lines changed: $(others)"
line="$(grep -- "$MARK" "$TABLE" 2>/dev/null)"
case "$line" in '*/3 * * * * '*) pass "AC-2 the line runs every 3 minutes" ;; *) fail "AC-2 the dispatcher line does not start with '*/3 * * * * ': $line" ;; esac
assert_contains "$line" "$SHIPFLOOR_HOME/factory/run-dispatcher.sh"
assert_contains "$line" " -l "
case "$line" in *"$MARK") pass "AC-2 the line ends with the marker" ;; *) fail "AC-2 the line does not end with '$MARK': $line" ;; esac
[ ! -e "$TMR" ] && pass "AC-2 no systemd unit written" || fail "AC-2 a systemd timer was written on a machine without systemd"
[ ! -e "$SHIPFLOOR_HOME/dispatcher.wake" ] && pass "wake: cron: no command (cron keeps its interval alone)" || fail "wake: cron: dispatcher.wake written: $(cat "$SHIPFLOOR_HOME/dispatcher.wake")"
fresh; run >/dev/null; : > "$SF_ST/no-systemd"; run --kind cron >/dev/null
[ ! -e "$SHIPFLOOR_HOME/dispatcher.wake" ] && pass "wake: moving from systemd to cron removes the systemd command" || fail "wake: dispatcher.wake left after moving to cron: $(cat "$SHIPFLOOR_HOME/dispatcher.wake")"
fresh; : > "$SF_ST/no-systemd"; run --every-min 10
[ "$rc" -eq 0 ] && [ "$(dispatcher_lines)" = 1 ] && pass "AC-2 an empty crontab (crontab -l fails) installs cleanly" || fail "AC-2 empty crontab: exit $rc, lines $(dispatcher_lines): $out"
case "$(grep -- "$MARK" "$TABLE" 2>/dev/null)" in '*/10 * * * * '*) pass "AC-2 --every-min 10 gives */10" ;; *) fail "AC-2 --every-min 10 line: $(grep -- "$MARK" "$TABLE" 2>/dev/null)" ;; esac
fresh; : > "$SF_ST/no-systemd"; run --status
assert_contains "$out" "not registered"
run >/dev/null; run --status
assert_contains "$out" "registered: cron"

# --- AC-3: macOS -> a launchd user agent that starts run-dispatcher.sh at the pace
fresh; SF_UNAME=Darwin run
[ "$rc" -eq 0 ] && pass "AC-3 install on macOS exits 0" || fail "AC-3 install on Darwin exited $rc (want 0): $out"
[ -f "$PLIST" ] && pass "AC-3 plist written to ~/Library/LaunchAgents" || fail "AC-3 no com.shipfloor.dispatcher.plist in ~/Library/LaunchAgents"
p="$(cat "$PLIST" 2>/dev/null)"
assert_contains "$p" "com.shipfloor.dispatcher"
assert_contains "$p" "$SHIPFLOOR_HOME/factory/run-dispatcher.sh"
assert_contains "$p" "<string>-l</string>"
assert_contains "$p" "StartInterval"
assert_contains "$p" "<integer>180</integer>"
assert_contains "$p" "AbandonProcessGroup"
assert_contains "$p" "$SHIPFLOOR_HOME"
[ "$(count "$PLIST" '<key>Label</key>')" = 1 ] && pass "AC-5 the plist is one job" || fail "AC-5 the plist holds $(count "$PLIST" '<key>Label</key>') Label keys (want one job)"
assert_contains "$(cat "$SF_ST/launchctl.log" 2>/dev/null)" "bootstrap gui/$(id -u) $PLIST"
[ "$(cat "$SHIPFLOOR_HOME/dispatcher.wake" 2>/dev/null)" = "$(printf '%s\n' launchctl kickstart "gui/$(id -u)/com.shipfloor.dispatcher")" ] && pass "wake: launchd: a run that ends kickstarts the agent" || fail "wake: launchd: dispatcher.wake is: $(cat "$SHIPFLOOR_HOME/dispatcher.wake" 2>/dev/null)"
fresh; SF_UNAME=Darwin run --every-min 5
assert_contains "$(cat "$PLIST" 2>/dev/null)" "<integer>300</integer>"
SF_UNAME=Darwin run --status
assert_contains "$out" "registered: launchd"

# --- AC-4: installing again leaves exactly one registration, exits 0, and reloads nothing
fresh; run >/dev/null; : > "$SF_ST/systemctl.log"; run; again="$out"
[ "$rc" -eq 0 ] && pass "AC-4 systemd: second install exits 0" || fail "AC-4 systemd: second install exited $rc: $out"
assert_contains "$again" "already registered"
[ "$(ls "$UNITS" 2>/dev/null | grep -c shipfloor-dispatcher)" = 2 ] && pass "AC-4 systemd: one service and one timer" || fail "AC-4 systemd: units found: $(ls "$UNITS" 2>/dev/null)"
[ "$(count "$SF_ST/systemctl.log" daemon-reload)" = 0 ] && [ "$(count "$SF_ST/systemctl.log" 'enable')" = 0 ] && [ "$(count "$SF_ST/systemctl.log" 'disable')" = 0 ] && pass "AC-4 systemd: nothing reloaded, enabled or disabled the second time" || fail "AC-4 systemd: second install called systemctl: $(cat "$SF_ST/systemctl.log")"

fresh; : > "$SF_ST/no-systemd"; printf '%s' "$OTHER_TABLE" > "$TABLE"; run >/dev/null; run; again="$out"
[ "$rc" -eq 0 ] && pass "AC-4 cron: second install exits 0" || fail "AC-4 cron: second install exited $rc: $out"
assert_contains "$again" "already registered"
[ "$(dispatcher_lines)" = 1 ] && pass "AC-4 cron: still exactly one line" || fail "AC-4 cron: $(dispatcher_lines) dispatcher lines"
[ "$(others)" = "$(printf '%s' "$OTHER_TABLE")" ] && pass "AC-4 cron: the other lines are unchanged" || fail "AC-4 cron: other lines changed: $(others)"
n="$(count "$SF_ST/crontab.log" '^-$')"
[ "$n" = 1 ] && pass "AC-4 cron: the table was written once, not again" || fail "AC-4 cron: crontab written $n times (want 1)"
run --every-min 5
[ "$(dispatcher_lines)" = 1 ] && case "$(grep -- "$MARK" "$TABLE")" in '*/5 * * * * '*) true ;; *) false ;; esac && pass "AC-4 cron: a new pace replaces the line, not adds one" || fail "AC-4 cron: after --every-min 5: $(grep -- "$MARK" "$TABLE")"

fresh; SF_UNAME=Darwin run >/dev/null; SF_UNAME=Darwin run; again="$out"
[ "$rc" -eq 0 ] && pass "AC-4 launchd: second install exits 0" || fail "AC-4 launchd: second install exited $rc: $out"
assert_contains "$again" "already registered"
[ "$(count "$SF_ST/launchctl.log" bootstrap)" = 1 ] && [ "$(count "$SF_ST/launchctl.log" bootout)" = 0 ] && pass "AC-4 launchd: one bootstrap, no bootout (a running cycle is not ended)" || fail "AC-4 launchd: launchctl calls: $(cat "$SF_ST/launchctl.log")"
[ "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && pass "AC-4 launchd: one plist" || fail "AC-4 launchd: plists: $(ls "$HOME/Library/LaunchAgents" 2>/dev/null)"

# installing one mechanism removes the others: a machine never has two timers
fresh; : > "$SF_ST/no-systemd"; printf '%s' "$OTHER_TABLE" > "$TABLE"; run >/dev/null
rm -f "$SF_ST/no-systemd"; run
[ -f "$TMR" ] && [ "$(dispatcher_lines)" = 0 ] && pass "AC-4 moving from cron to systemd leaves no crontab line" || fail "AC-4 cron line still there after a systemd install (lines $(dispatcher_lines), timer $([ -f "$TMR" ] && echo yes || echo no))"
[ "$(others)" = "$(printf '%s' "$OTHER_TABLE")" ] && pass "AC-4 the crontab's other lines survive the move" || fail "AC-4 crontab after the move: $(others)"

# --- AC-6: a cycle started by cron with a near-empty environment finds claude, gh, git and Python
fresh; : > "$SF_ST/no-systemd"; run >/dev/null
SEEN="$T/seen"
printf '#!/usr/bin/env bash\n{ echo "claude=$(command -v claude)"; echo "gh=$(command -v gh)"; echo "git=$(command -v git)"; echo "python=$(command -v python3 || command -v python)"; } > "%s"\n' "$SEEN" > "$SHIPFLOOR_HOME/factory/shipfloor-dispatch.sh"
cmd="$(grep -- "$MARK" "$TABLE" 2>/dev/null | sed -E 's/^([^ ]+ +){5}//; s/ *# shipfloor-dispatcher$//')"
if [ -n "$cmd" ]; then
  env -i HOME="$HOME" PATH=/usr/bin:/bin ${SYSTEMROOT:+SYSTEMROOT="$SYSTEMROOT"} sh -c "$cmd" >/dev/null 2>&1
else fail "AC-6 no dispatcher line in the crontab to run"; fi
seen="$(cat "$SEEN" 2>/dev/null)"
assert_contains "$seen" "claude=$FAKEBIN/claude"
assert_contains "$seen" "gh=$FAKEBIN/gh"
case "$seen" in *"git=/"*|*"git=C:"*|*"git=c:"*) pass "AC-6 git resolves" ;; *) fail "AC-6 git did not resolve under env -i: $seen" ;; esac
case "$seen" in *"python=/"*|*"python=C:"*|*"python=c:"*) pass "AC-6 Python resolves" ;; *) fail "AC-6 Python did not resolve under env -i: $seen" ;; esac
[ "$(wc -l < "$SHIPFLOOR_HOME/dispatcher.path" | tr -d ' ')" -le 1 ] 2>/dev/null && pass "AC-6 dispatcher.path is one line" || fail "AC-6 dispatcher.path is not one line"

# --- #218 AC-3: a reinstall needs no drop-in: the generated entries start run-dispatcher.sh (which sets TMPDIR) with no TMPDIR of their own
fresh; run >/dev/null; run; again="$out"
assert_contains "$again" "already registered"
case "$(cat "$SVC" "$TMR" 2>/dev/null)" in *TMPDIR*) fail "AC-3 the systemd unit sets a TMPDIR of its own" ;; *) pass "AC-3 the systemd unit sets no TMPDIR" ;; esac
fresh; SF_UNAME=Darwin run >/dev/null
case "$(cat "$PLIST" 2>/dev/null)" in *TMPDIR*) fail "AC-3 the plist sets a TMPDIR of its own" ;; *) pass "AC-3 the plist sets no TMPDIR" ;; esac
fresh; : > "$SF_ST/no-systemd"; run >/dev/null
case "$(grep -- "$MARK" "$TABLE" 2>/dev/null)" in *TMPDIR*) fail "AC-3 the cron line sets a TMPDIR of its own" ;; *) pass "AC-3 the cron line sets no TMPDIR" ;; esac
# the entry the install registered, run with a foreign TMPDIR, gives the cycle <SHIPFLOOR_HOME>/tmp
printf '#!/usr/bin/env bash\necho "$TMPDIR" > "%s/seen-tmpdir"\n' "$T" > "$SHIPFLOOR_HOME/factory/shipfloor-dispatch.sh"
cmd="$(grep -- "$MARK" "$TABLE" 2>/dev/null | sed -E 's/^([^ ]+ +){5}//; s/ *# shipfloor-dispatcher$//')"
[ -n "$cmd" ] && env TMPDIR=/tmp sh -c "$cmd" >/dev/null 2>&1
[ "$(cat "$T/seen-tmpdir" 2>/dev/null)" = "$SHIPFLOOR_HOME/tmp" ] && [ -d "$SHIPFLOOR_HOME/tmp" ] && pass "AC-3 the registered entry runs the cycle with TMPDIR=<SHIPFLOOR_HOME>/tmp, no drop-in" || fail "AC-3 the registered entry gave the cycle TMPDIR='$(cat "$T/seen-tmpdir" 2>/dev/null)' (want $SHIPFLOOR_HOME/tmp)"

# --- AC-7: uninstall leaves nothing behind
fresh; run >/dev/null; run --uninstall
[ "$rc" -eq 0 ] && pass "AC-7 systemd: uninstall exits 0" || fail "AC-7 systemd: uninstall exited $rc: $out"
[ ! -e "$SVC" ] && [ ! -e "$TMR" ] && pass "AC-7 systemd: both unit files deleted" || fail "AC-7 systemd: units left in $UNITS"
assert_contains "$(cat "$SF_ST/systemctl.log" 2>/dev/null)" "disable --now shipfloor-dispatcher.timer"
[ ! -e "$SHIPFLOOR_HOME/dispatcher.path" ] && pass "AC-7 dispatcher.path deleted" || fail "AC-7 dispatcher.path left behind"
[ ! -e "$SHIPFLOOR_HOME/dispatcher.wake" ] && pass "AC-7 dispatcher.wake deleted" || fail "AC-7 dispatcher.wake left behind"
run --status; [ "$rc" -eq 1 ] && pass "AC-7 --status says not registered afterwards" || fail "AC-7 --status after uninstall exited $rc: $out"

fresh; : > "$SF_ST/no-systemd"; printf '%s' "$OTHER_TABLE" > "$TABLE"; run >/dev/null; run --uninstall
[ "$rc" -eq 0 ] && pass "AC-7 cron: uninstall exits 0" || fail "AC-7 cron: uninstall exited $rc: $out"
[ "$(dispatcher_lines)" = 0 ] && [ "$(others)" = "$(printf '%s' "$OTHER_TABLE")" ] && pass "AC-7 cron: no dispatcher line, other lines unchanged" || fail "AC-7 cron: table is: $(cat "$TABLE" 2>/dev/null)"

fresh; SF_UNAME=Darwin run >/dev/null; SF_UNAME=Darwin run --uninstall
[ "$rc" -eq 0 ] && pass "AC-7 launchd: uninstall exits 0" || fail "AC-7 launchd: uninstall exited $rc: $out"
[ ! -e "$PLIST" ] && pass "AC-7 launchd: plist deleted" || fail "AC-7 launchd: plist left behind"
assert_contains "$(cat "$SF_ST/launchctl.log" 2>/dev/null)" "bootout gui/$(id -u)"

# every mechanism at once: a crontab line, unit files and a plist, all removed
fresh; : > "$SF_ST/no-systemd"; printf '%s' "$OTHER_TABLE" > "$TABLE"; run >/dev/null
mkdir -p "$UNITS" "$(dirname "$PLIST")"; : > "$SVC"; : > "$TMR"; : > "$PLIST"
rm -f "$SF_ST/no-systemd"; run --uninstall
[ "$rc" -eq 0 ] && [ ! -e "$SVC" ] && [ ! -e "$TMR" ] && [ ! -e "$PLIST" ] && [ "$(dispatcher_lines)" = 0 ] && pass "AC-7 uninstall removes every mechanism's registration" || fail "AC-7 left behind (exit $rc): $(ls "$UNITS" "$(dirname "$PLIST")" 2>/dev/null) lines $(dispatcher_lines)"
[ "$(others)" = "$(printf '%s' "$OTHER_TABLE")" ] && pass "AC-7 the other crontab lines survive" || fail "AC-7 crontab after uninstall: $(others)"

# nothing registered: exits 0 and changes nothing
fresh; printf '%s' "$OTHER_TABLE" > "$TABLE"; cp "$TABLE" "$T/before"; run --uninstall
[ "$rc" -eq 0 ] && pass "AC-7 nothing registered: exits 0" || fail "AC-7 nothing registered: uninstall exited $rc (want 0): $out"
cmp -s "$TABLE" "$T/before" && pass "AC-7 nothing registered: the crontab is byte for byte the same" || fail "AC-7 nothing registered: crontab changed"
[ "$(count "$SF_ST/crontab.log" '^-$')" = 0 ] && [ "$(count "$SF_ST/crontab.log" '^-r')" = 0 ] && pass "AC-7 nothing registered: the crontab is not rewritten" || fail "AC-7 nothing registered: crontab calls: $(cat "$SF_ST/crontab.log")"
fresh; run --uninstall
[ "$rc" -eq 0 ] && [ ! -e "$TABLE" ] && pass "AC-7 nothing registered, no crontab: exits 0 and creates none" || fail "AC-7 no crontab at all: exit $rc, table $([ -e "$TABLE" ] && echo created || echo absent): $out"

# --- #219 AC-1: no limits (no key, or all none) -> a unit with no resource directive, status says "limits: none"
LIMITED='limits: {memory_max: 10G, cpu_weight: 200, cpu_quota: 150%}'$'\n'
fresh; run
[ "$rc" -eq 0 ] && ! grep -qE '^(MemoryMax|MemoryHigh|CPUWeight|CPUQuota)=' "$SVC" && pass "AC-1 limits: no config key installs a unit with no CPU or memory directive" || fail "AC-1 limits: unit without a limit config carries a directive (exit $rc): $(cat "$SVC" 2>/dev/null)"
run --status
assert_contains "$out" "limits: none"
fresh; printf 'limits: {memory_max: none, cpu_weight: none, cpu_quota: none}\n' > "$SHIPFLOOR_HOME/config.yml"; run
[ "$rc" -eq 0 ] && ! grep -qE '^(MemoryMax|MemoryHigh|CPUWeight|CPUQuota)=' "$SVC" && pass "AC-1 limits: all none installs without directives" || fail "AC-1 limits: all-none config wrote a directive (exit $rc): $(cat "$SVC" 2>/dev/null)"
case "$(lower "$out")" in *"not supported"*) fail "AC-1 limits: no limit set but the installer warned: $out" ;; *) pass "AC-1 limits: no warning when nothing is limited" ;; esac
run --status
assert_contains "$out" "limits: none"

# --- #219 AC-2: Linux with systemd -> the unit carries the limits; flags override the config; only a change reloads
fresh; printf '%s' "$LIMITED" > "$SHIPFLOOR_HOME/config.yml"; run
[ "$rc" -eq 0 ] && pass "AC-2 limits: install with limits exits 0" || fail "AC-2 limits: install exited $rc: $out"
svc="$(cat "$SVC" 2>/dev/null)"
assert_contains "$svc" "MemoryMax=10G"
assert_contains "$svc" "MemoryHigh="
assert_contains "$svc" "CPUWeight=200"
assert_contains "$svc" "CPUQuota=150%"
assert_contains "$svc" "KillMode=process"
run --status
assert_contains "$out" "limits: memory_max=10G cpu_weight=200 cpu_quota=150%"
: > "$SF_ST/systemctl.log"; run
assert_contains "$out" "already registered"
[ "$(count "$SF_ST/systemctl.log" daemon-reload)" = 0 ] && pass "AC-2 limits: the same limits again reload nothing" || fail "AC-2 limits: unchanged limits reloaded: $(cat "$SF_ST/systemctl.log")"
run --memory-max 4G --cpu-weight 50 --cpu-quota 80%
svc="$(cat "$SVC" 2>/dev/null)"
assert_contains "$svc" "MemoryMax=4G"
assert_contains "$svc" "CPUWeight=50"
assert_contains "$svc" "CPUQuota=80%"
[ "$(count "$SF_ST/systemctl.log" daemon-reload)" -ge 1 ] && pass "AC-2 limits: a changed limit reloads the unit" || fail "AC-2 limits: changed limits did not reload: $(cat "$SF_ST/systemctl.log")"
run --memory-max none --cpu-weight none --cpu-quota none
! grep -qE '^(MemoryMax|MemoryHigh|CPUWeight|CPUQuota)=' "$SVC" && pass "AC-2 limits: none on every flag lifts the limits from the unit" || fail "AC-2 limits: none flags left a directive: $(cat "$SVC")"
fresh; run --cpu-weight 0
[ "$rc" -ne 0 ] && [ ! -e "$SVC" ] && pass "AC-2 limits: an invalid cpu-weight is refused and registers nothing" || fail "AC-2 limits: --cpu-weight 0 exit $rc, unit $([ -e "$SVC" ] && echo written || echo absent): $out"

# --- #219 AC-3: macOS, and Linux on cron -> installed without limits, with a warning
fresh; printf '%s' "$LIMITED" > "$SHIPFLOOR_HOME/config.yml"; SF_UNAME=Darwin run
[ "$rc" -eq 0 ] && [ -f "$PLIST" ] && pass "AC-3 limits: macOS installs the agent" || fail "AC-3 limits: macOS install exit $rc, plist $([ -f "$PLIST" ] && echo yes || echo no): $out"
case "$(lower "$out")" in *"not supported"*) pass "AC-3 limits: macOS warns that limits are not supported" ;; *) fail "AC-3 limits: macOS gave no not-supported warning: $out" ;; esac
case "$(cat "$PLIST" 2>/dev/null)" in *MemoryMax*|*CPUQuota*|*CPUWeight*) fail "AC-3 limits: the plist carries a systemd directive" ;; *) pass "AC-3 limits: the plist carries no limit" ;; esac
SF_UNAME=Darwin run --status
assert_contains "$out" "limits: not supported (launchd)"
fresh; : > "$SF_ST/no-systemd"; printf '%s' "$LIMITED" > "$SHIPFLOOR_HOME/config.yml"; run
[ "$rc" -eq 0 ] && [ "$(dispatcher_lines)" = 1 ] && pass "AC-3 limits: cron installs its one line" || fail "AC-3 limits: cron install exit $rc, lines $(dispatcher_lines): $out"
case "$(lower "$out")" in *"not supported with cron"*) pass "AC-3 limits: cron warns that limits are not supported" ;; *) fail "AC-3 limits: cron gave no not-supported warning: $out" ;; esac

finish
