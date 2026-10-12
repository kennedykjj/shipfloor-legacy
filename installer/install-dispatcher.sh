#!/usr/bin/env bash
# Registers the shipfloor dispatcher on Linux (systemd user timer, else the user's crontab) and macOS
# (launchd user agent): every 1, 3, 5 or 10 minutes (--every-min, else dispatcher.every_min of the machine
# config, else 3). It starts the installed copy: run 'shipfloor install' first. Windows has install-dispatcher.ps1.
#   bash install-dispatcher.sh [--every-min 1|3|5|10] [--kind systemd|cron|launchd] [--dry-run]
#   bash install-dispatcher.sh --uninstall   removes every registration of every mechanism
#   bash install-dispatcher.sh --status      prints "registered: <kind>" (exit 0) or "not registered" (exit 1)
# The installing shell's PATH goes to <home>/dispatcher.path: run-dispatcher.sh puts it in front of the timer's.
H="${SHIPFLOOR_HOME:-$HOME/.shipfloor}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-dispatcher.sh"
UNIT=shipfloor-dispatcher; LABEL=com.shipfloor.dispatcher; MARK='# shipfloor-dispatcher'
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; SERVICE="$UNITS/$UNIT.service"; TIMER="$UNITS/$UNIT.timer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

die() { echo "install-dispatcher: $1" >&2; exit "${2:-1}"; }
has() { command -v "$1" >/dev/null 2>&1; }

EVERY=; KIND="${SHIPFLOOR_SCHEDULER_KIND:-}"; MODE=install; DRY=
while [ $# -gt 0 ]; do
  case "$1" in
    --every-min) EVERY="${2:-none}"; shift ;;
    --kind) KIND="${2:-none}"; shift ;;
    --uninstall) MODE=uninstall ;;
    --status) MODE=status ;;
    --dry-run) DRY=1 ;;
    *) die "unknown option '$1'" 2 ;;
  esac
  shift
done
case "${EVERY:-3}" in 1|3|5|10) ;; *) die "--every-min takes 1, 3, 5 or 10 (got '$EVERY')" 2 ;; esac
case "$KIND" in ""|systemd|cron|launchd) ;; *) die "--kind takes systemd, cron or launchd (got '$KIND')" 2 ;; esac

OS="$(uname -s)"
case "$OS" in
  MINGW*|MSYS*|CYGWIN*) [ "$MODE" = status ] && exit 2; die "on Windows run installer/install-dispatcher.ps1" ;;
esac
UIDN="$(id -u)"; SETENV="${SHIPFLOOR_HOME+1}"; CHANGED=
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

systemd_has() { has systemctl && [ -e "$TIMER" ] && systemctl --user is-active -q "$UNIT.timer" >/dev/null 2>&1; }
cron_has() { has crontab && crontab -l 2>/dev/null | grep -q -- "$MARK"; }
launchd_has() { has launchctl && [ -e "$PLIST" ] && launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1; }

cron_set() {  # cron_set [line]: the crontab without the dispatcher lines, plus line; written only when it changes
  has crontab || return 0
  crontab -l > "$TMP/cron.old" 2>/dev/null
  grep -v -- "$MARK" "$TMP/cron.old" > "$TMP/cron.new"
  [ -z "${1:-}" ] || printf '%s\n' "$1" >> "$TMP/cron.new"
  cmp -s "$TMP/cron.old" "$TMP/cron.new" && return 0
  crontab - < "$TMP/cron.new" || die "could not write the crontab"
  CHANGED=1
}
remove_cron() { cron_set; }
remove_systemd() {
  [ -e "$SERVICE" ] || [ -e "$TIMER" ] || return 0
  if has systemctl; then systemctl --user disable --now "$UNIT.timer" >/dev/null 2>&1; fi
  rm -f "$SERVICE" "$TIMER"
  if has systemctl; then systemctl --user daemon-reload >/dev/null 2>&1; fi
  return 0
}
remove_launchd() {
  if has launchctl && launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1; then launchctl bootout "gui/$UIDN/$LABEL" >/dev/null 2>&1; fi
  rm -f "$PLIST"
}

if [ "$MODE" = status ]; then
  for k in systemd cron launchd; do "${k}_has" && { echo "registered: $k"; exit 0; }; done
  echo "not registered; register it with: bash $SELF"; exit 1
fi
if [ "$MODE" = uninstall ]; then
  for k in systemd cron launchd; do "remove_$k"; done
  rm -f "$H/dispatcher.path"
  echo "dispatcher unregistered"; exit 0
fi

if [ -z "$KIND" ]; then
  if [ "$OS" = Darwin ]; then KIND=launchd
  elif has systemctl && systemctl --user show-environment >/dev/null 2>&1; then KIND=systemd
  elif has crontab; then KIND=cron
  else die "no systemd user session and no crontab; enable one of them"; fi
fi
case "$KIND" in systemd) TOOL=systemctl ;; cron) TOOL=crontab ;; launchd) TOOL=launchctl ;; esac
has "$TOOL" || die "$TOOL not found, cannot register with $KIND"

if [ -z "$EVERY" ]; then
  EVERY=3
  if [ -f "$H/factory/shipfloor-config.sh" ]; then
    got="$(bash "$H/factory/shipfloor-config.sh" machine values dispatcher.every_min 2>/dev/null | tr -d '\0')"
    case "$got" in 1|3|5|10) EVERY="$got" ;; esac
  fi
fi
[ -z "$DRY" ] || { echo "dispatcher: $KIND, every $EVERY minutes (dry run, nothing changed)"; exit 0; }

ENTRY="$H/factory/run-dispatcher.sh"
[ -f "$ENTRY" ] || die "run 'shipfloor install' first ($ENTRY not found)"
BASH_BIN="$(command -v bash)"
"$BASH_BIN" -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))' ||
  die "needs bash 4.4 or newer on PATH ($BASH_BIN is $("$BASH_BIN" -c 'echo $BASH_VERSION')); install one, e.g. 'brew install bash'"
START="$BASH_BIN -l $ENTRY"

for k in systemd cron launchd; do [ "$k" = "$KIND" ] || "remove_$k"; done
mkdir -p "$H"
[ "$(cat "$H/dispatcher.path" 2>/dev/null)" = "$PATH" ] || { printf '%s\n' "$PATH" > "$H/dispatcher.path"; CHANGED=1; }

install_systemd() {
  cat > "$TMP/service" <<EOF
[Unit]
Description=shipfloor dispatcher cycle

[Service]
Type=oneshot
KillMode=process
$([ -z "$SETENV" ] || echo "Environment=SHIPFLOOR_HOME=$H")
ExecStart=$START
EOF
  cat > "$TMP/timer" <<EOF
[Unit]
Description=shipfloor dispatcher, every $EVERY minutes

[Timer]
OnCalendar=*:0/$EVERY

[Install]
WantedBy=timers.target
EOF
  local act=
  cmp -s "$TMP/service" "$SERVICE" 2>/dev/null && cmp -s "$TMP/timer" "$TIMER" 2>/dev/null || act=1
  systemctl --user is-active -q "$UNIT.timer" >/dev/null 2>&1 || act=1
  if [ -n "$act" ]; then
    mkdir -p "$UNITS"; cp "$TMP/service" "$SERVICE"; cp "$TMP/timer" "$TIMER"
    systemctl --user daemon-reload || die "systemctl --user daemon-reload failed"
    systemctl --user enable --now "$UNIT.timer" || die "systemctl --user enable --now $UNIT.timer failed"
    CHANGED=1
  fi
}
install_cron() {
  cron_set "*/$EVERY * * * * ${SETENV:+SHIPFLOOR_HOME=$H }$START $MARK"
}
install_launchd() {
  cat > "$TMP/plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BASH_BIN</string><string>-l</string><string>$ENTRY</string></array>
  <key>StartInterval</key><integer>$((EVERY * 60))</integer>
  <key>AbandonProcessGroup</key><true/>
$([ -z "$SETENV" ] || printf '  <key>EnvironmentVariables</key>\n  <dict><key>SHIPFLOOR_HOME</key><string>%s</string></dict>\n' "$H")
</dict>
</plist>
EOF
  local loaded=
  launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1 && loaded=1
  if [ -n "$loaded" ] && cmp -s "$TMP/plist" "$PLIST" 2>/dev/null; then return 0; fi
  [ -z "$loaded" ] || launchctl bootout "gui/$UIDN/$LABEL" >/dev/null 2>&1
  mkdir -p "$(dirname "$PLIST")"; cp "$TMP/plist" "$PLIST"
  launchctl bootstrap "gui/$UIDN" "$PLIST" || die "launchctl bootstrap failed"
  CHANGED=1
}
"install_$KIND"

[ -n "$CHANGED" ] && echo "dispatcher registered with $KIND, every $EVERY minutes" || echo "dispatcher already registered ($KIND, every $EVERY minutes)"
if [ "$KIND" = systemd ] && has loginctl; then
  user="$(id -un)"
  if loginctl show-user "$user" 2>/dev/null | grep -qx 'Linger=yes'; then
    echo "lingering is on: the dispatcher keeps running after you log out"
  else
    echo "lingering is off: the dispatcher stops when you log out; turn it on with: loginctl enable-linger $user"
  fi
fi
exit 0
