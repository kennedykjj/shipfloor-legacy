#!/usr/bin/env bash
# suite: integration
# Notifications when the factory needs the owner (shipfloor_notify.py, notify.pt-BR.json, the dashboard's machine.notify
# checked by shipfloor_config.py). The behavior is in process: py/notify_cycle.py (waits, reminders, the factory
# stuck, production, quiet hours and the digest) and py/notify_channels.py (what the push carries, failing channels,
# the three transports, the settings). Here, through real processes: shipfloor_notify.py's command line handing a
# channel to SHIPFLOOR_NOTIFY_SEND, and a dispatcher cycle (shipfloor-dispatch.sh) that ends in a notification and
# whose exit code and log stay the same when a channel fails (AC-7).
source "$(dirname "$0")/lib.sh"
py_suite notify_cycle
py_suite notify_channels
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
NOTIFY="$FACTORY_DIR/shipfloor_notify.py"
MD="$FACTORY_DIR/shipfloor-dispatch.sh"
T=$'\t'
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export SHIPFLOOR_BASH="$(nat "$(command -v bash)")"

setup() {  # a home with one project (shop) and a sender that records what each channel is handed
  H="$(mktemp -d)"; P="$H/projects/shop"; mkdir -p "$P" "$H/logs"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
  SENT="$H/sent"; : > "$SENT"
  cat > "$H/send" <<'SH'
#!/usr/bin/env bash
body="${3//$'\n'/|}"; body="${body//$'\r'/}"
printf '%s\t%s\t%s\n' "$1" "$2" "$body" >> "$(dirname "$0")/sent"
case " ${FAIL_CHANNELS:-} " in *" $1 "*) echo "boom: $1 is down" >&2; exit 1 ;; esac
exit 0
SH
  chmod +x "$H/send"
  export SHIPFLOOR_NOTIFY_SEND="$(nat "$H/send")" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 FAKE_GH_DIR="$(mktemp -d)"
  printf '{"ts":"2026-10-11T10:00:00-03:00","paused":false,"usage_limited":false,"projects":{"shop":{"paused":false,"skipped":false,"blocked":0,"blocked_cards":[]}}}\n' > "$H/logs/health-2026-10.jsonl"
}

# the command line: cycle --home H --now T hands each message to the sender as <channel> <title> <body>
setup; printf 'notify: {channels: {toast: true}}\n' > "$H/config.yml"; printf '7\tSpec Review\tI7\n' > "$P/board.tsv"
$PY -I "$(nat "$NOTIFY")" cycle --home "$(nat "$H")" --now 2026-10-11T10:00:00 > "$H/out" 2> "$H/err"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$H/out" ] && pass "cycle: exit 0, nothing on stdout" || fail "cycle: exit $rc: $(cat "$H/out" "$H/err")"
grep -qxF "toast${T}shop · #7 waits for you${T}Seven|Spec Review · spec to review" "$SENT" && pass "cycle: the sender got channel, title and body" || fail "sent: $(cat "$SENT")"
[ -f "$H/notify.json" ] && pass "cycle: what was told is in notify.json" || fail "no notify.json"
FAIL_CHANNELS=toast $PY -I "$(nat "$NOTIFY")" cycle --home "$(nat "$H")" --now 2026-10-11T10:05:00 2> "$H/err"; rc=$?
[ "$rc" = 0 ] && pass "cycle: nothing new, exit 0" || fail "cycle: exit $rc: $(cat "$H/err")"
assert_exit 2 $PY -I "$NOTIFY" cycle
assert_exit 2 $PY -I "$NOTIFY" send --home "$H"

# AC-7: a dispatcher cycle ends as it would have without notifications; the failure is one line in its log
project() {  # project <slug>: a repo with a remote whose main carries .shipfloor/factory.yml, registered in $SHIPFLOOR_HOME
  local slug="$1" remote r
  remote="$(mktemp -d)"; git init -q --bare "$remote"
  r="$(new_repo)"; mkdir -p "$r/.shipfloor"
  sed "s/name: shop/name: $slug/" "$FACTORY_DIR/test/fixture/factory.yml" > "$r/.shipfloor/factory.yml"
  git -C "$r" add -A; git -C "$r" commit -qm cfg; git -C "$r" remote add origin "$remote"; git -C "$r" push -q origin main
  printf '%s\t%s\t%s\tmain\n' "$slug" "$r" "$SHIPFLOOR_HOME/projects/$slug/wt" >> "$SHIPFLOOR_HOME/registry.tsv"
}
dsetup() {  # dsetup <config>: a dispatcher home whose project has card 9 waiting in Spec Review
  setup; export SHIPFLOOR_HOME="$H"; : > "$H/registry.tsv"; project shop
  printf '#!/usr/bin/env bash\nexit 3\n' > "$H/dispatch"; chmod +x "$H/dispatch"; export SHIPFLOOR_DISPATCH="$H/dispatch"
  printf '9\tSpec Review\tI9\n' > "$P/board.tsv"; printf '%s\n' "$1" > "$H/config.yml"
}
dcycle() {  # dcycle <failing channels>: one dispatcher cycle; exit code in $H/rc, its log in $H/disp.err
  FAIL_CHANNELS="$1" bash "$MD" >/dev/null 2>"$H/disp.err"; echo $? > "$H/rc"
}
dsetup $'notify: {channels: {toast: false, ntfy: false}}'
dcycle ""; want_rc="$(cat "$H/rc")"; want_log="$(cat "$H/disp.err")"
dsetup $'notify: {channels: {toast: true, ntfy: true}, ntfy_topic: secret_topic_xyz}'
dcycle "toast"
got="$(grep -c "^ntfy${T}shop · #9 waits for you" "$SENT")"
[ "$got" = 1 ] && pass "AC-7 the dispatcher's cycle ends in a notification, and the push delivers" || fail "AC-7 expected the cycle to push '#9 waits for you' once, got $got: $(cat "$SENT")"
[ "$(cat "$H/rc")" = "$want_rc" ] && pass "AC-7 the cycle's exit code is the one it has without notifications ($want_rc)" || fail "AC-7 exit code $(cat "$H/rc"), without notifications $want_rc"
got="$(grep -c 'shipfloor: notify: toast failed: the sender failed' "$H/disp.err")"
[ "$got" = 1 ] && pass "AC-7 the failure is one line in the dispatcher's log" || fail "AC-7 expected one 'shipfloor: notify: toast failed:' line in the dispatcher's log, got $got: $(cat "$H/disp.err")"
rest="$(grep -v 'shipfloor: notify:' "$H/disp.err")"
[ "$rest" = "$want_log" ] && pass "AC-7 the rest of the log is what it is without notifications" || fail "AC-7 the log differs apart from the failure line: '$rest' vs '$want_log'"
case "$(cat "$H/disp.err")" in *secret_topic_xyz*) fail "AC-7 the dispatcher's log holds the topic" ;; *) pass "AC-7 the dispatcher's log never holds the topic" ;; esac
finish
