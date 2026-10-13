#!/usr/bin/env bash
# Notification channels: the phone push carries only the project, the card's number, title and state, and nothing
# leaves the machine without a topic (AC-6); a channel that fails changes nothing else: the cycle ends as it would
# have, the failure is one line in the dispatcher's log and the other channel still delivers (AC-7).
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
NOTIFY="$FACTORY_DIR/shipfloor_notify.py"
MD="$FACTORY_DIR/shipfloor-dispatch.sh"
T=$'\t'
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
export SHIPFLOOR_BASH="$(nat "$(command -v bash)")"

setup() {  # a home with one project (shop), a sender that records what each channel is handed, a gh with titles
  H="$(mktemp -d)"; P="$H/projects/shop"; mkdir -p "$P" "$H/logs"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
  SENT="$H/sent"; : > "$SENT"
  cat > "$H/send" <<'EOF'
#!/usr/bin/env bash
body="${3//$'\n'/|}"; body="${body//$'\r'/}"
printf '%s\t%s\t%s\n' "$1" "$2" "$body" >> "$(dirname "$0")/sent"
case " ${FAIL_CHANNELS:-} " in *" $1 "*) echo "boom: $1 is down" >&2; exit 1 ;; esac
exit 0
EOF
  LONG="$(printf 'abcdefghij%.0s' 1 2 3 4 5 6 7 8 9 10)"
  cat > "$H/gh" <<EOF
#!/usr/bin/env bash
[ -e "\$(dirname "\$0")/gh-fail" ] && { echo "gh: network error" >&2; exit 1; }
case "\$*" in
  "issue list"*) echo '[{"number":7,"title":"Seven"},{"number":8,"title":"Eight"},{"number":13,"title":"$LONG"}]' ;;
  *) echo '[]' ;;
esac
EOF
  chmod +x "$H/send" "$H/gh"
  export SHIPFLOOR_NOTIFY_SEND="$(nat "$H/send")" FACTORY_GH="$(nat "$H/gh")"
  printf '{"ts":"2026-10-11T10:00:00-03:00","paused":false,"usage_limited":false,"projects":{"shop":{"paused":false,"skipped":false,"blocked":0,"blocked_cards":[]}}}\n' > "$H/logs/health-2026-10.jsonl"
}
board() { printf '%b' "$1" > "$P/board.tsv"; }
conf() { printf '%s\n' "$1" > "$H/config.yml"; }
cycle() { $PY -I "$(nat "$NOTIFY")" cycle --home "$(nat "$H")" --now "$1" >/dev/null 2>>"$H/err"; }
n_is() {
  local got; got="$(grep -c '' "$SENT")"
  [ "$got" = "$1" ] && pass "$2" || fail "$2: expected $1 notification(s), got $got: $(tr '\n' ';' < "$SENT")"
}
has() { grep -qxF -- "$1" "$SENT" && pass "$2" || fail "$2: expected '$1' in: $(tr '\n' ';' < "$SENT")"; }
lacks() {  # lacks <text> <what>: nothing sent, and nothing logged, holds the text
  if grep -qF -- "$1" "$SENT" "$H/err" 2>/dev/null; then fail "$2: found '$1'"; else pass "$2"; fi
}
BOTH=$'notify: {channels: {toast: true, ntfy: true}, ntfy_topic: secret_topic_xyz}'

# AC-6: the push carries the project, the card's number, title and state and nothing else
setup; conf "$BOTH"; board '7\tSpec Review\tI7\n'
printf '2026-10-11T09:00:00\tcannot bring the control checkout: fatal: /secret/dir/.git/index.lock ghp_TOKEN123\n' > "$P/SKIPPED"
mkdir -p "$P/reviews"; printf '<html>SPEC-SECRET-TEXT in /secret/dir/src/Main.kt</html>' > "$P/reviews/7.html"
cycle 2026-10-11T10:00:00
has "ntfy${T}shop · #7 waits for you${T}Seven|Spec Review · spec to review" "AC-6 the push has the project, number, title and state"
has "ntfy${T}shop · the factory is stuck${T}The dispatcher skips this project. The dashboard says why." "AC-6 a skipped project is pushed without its reason"
lacks "SPEC-SECRET-TEXT" "AC-6 no spec text"
lacks "/secret/dir" "AC-6 no paths"
lacks "ghp_TOKEN123" "AC-6 no tokens"
lacks "secret_topic_xyz" "AC-6 the topic is neither pushed in the text nor logged"

# AC-6: titles are cut at 80 characters with an ellipsis
setup; conf "$BOTH"; board '13\tSpec Review\tI13\n'
cycle 2026-10-11T10:00:00
line="$(grep -F 'shop · #13 waits for you' "$SENT" | grep '^ntfy' | head -1)"; body="${line##*$'\t'}"; first="${body%%|*}"
if [ -n "$line" ] && [[ "$first" == abcdefghijabcdefghij* ]] && [[ "$first" == *"…" ]] && [ "${#first}" -ge 70 ] && [ "${#first}" -le 83 ]; then
  pass "AC-6 a title of 100 characters is cut at 80 with an ellipsis"
else
  fail "AC-6 a title of 100 characters is cut at 80 with an ellipsis: ntfy line was '$line'"
fi

# AC-6: with no topic set nothing leaves the machine
setup; conf $'notify: {channels: {toast: true}}'; board '7\tSpec Review\tI7\n'
cycle 2026-10-11T10:00:00
has "toast${T}shop · #7 waits for you${T}Seven|Spec Review · spec to review" "AC-6 without a topic the toast still tells"
if grep -q '^ntfy' "$SENT"; then fail "AC-6 pushed with no topic set: $(cat "$SENT")"; else pass "AC-6 no topic, no push"; fi
setup; conf $'notify: {channels: {toast: true}, ntfy_topic: secret_topic_xyz}'; board '7\tSpec Review\tI7\n'
cycle 2026-10-11T10:00:00
has "toast${T}shop · #7 waits for you${T}Seven|Spec Review · spec to review" "AC-6 a topic with the phone switch off still only toasts"
if grep -q '^ntfy' "$SENT"; then fail "AC-6 pushed with the phone push off: $(cat "$SENT")"; else pass "AC-6 phone push off, no push"; fi

# AC-7: a channel that fails: the other still delivers, the failure is one line, the topic is never in it
setup; conf "$BOTH"; board '7\tSpec Review\tI7\n'
FAIL_CHANNELS="toast" cycle 2026-10-11T10:00:00
has "ntfy${T}shop · #7 waits for you${T}Seven|Spec Review · spec to review" "AC-7 the push delivers when the toast fails"
got="$(grep -c 'shipfloor: notify: toast failed:' "$H/err" 2>/dev/null)"
[ "$got" = 1 ] && pass "AC-7 one log line for the failed channel" || fail "AC-7 expected one 'shipfloor: notify: toast failed:' line, got ${got:-0}: $(cat "$H/err" 2>/dev/null)"
lacks "secret_topic_xyz" "AC-7 the log never holds the topic"
FAIL_CHANNELS="toast" cycle 2026-10-11T10:05:00
n_is 2 "AC-7 a wait one channel delivered is not tried again"

# AC-7: with every channel failing the wait is tried again next cycle
setup; conf "$BOTH"; board '7\tSpec Review\tI7\n'
FAIL_CHANNELS="toast ntfy" cycle 2026-10-11T10:00:00
n_is 2 "AC-7 both channels were tried"
FAIL_CHANNELS="toast ntfy" cycle 2026-10-11T10:05:00
n_is 4 "AC-7 every channel down: the wait is tried again next cycle"
cycle 2026-10-11T10:10:00
n_is 6 "AC-7 and tried again until a channel delivers"
cycle 2026-10-11T10:15:00
n_is 6 "AC-7 then told"

# AC-7: titles that cannot be read: the notification goes out with the number only
setup; conf $'notify: {channels: {toast: true}}'; board '7\tSpec Review\tI7\n'; : > "$H/gh-fail"
cycle 2026-10-11T10:00:00
has "toast${T}shop · #7 waits for you${T}Spec Review · spec to review" "AC-7 gh down: the notification goes out with the number only"

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
  export FAKE_GH_DIR="$(mktemp -d)"; board '9\tSpec Review\tI9\n'; conf "$1"
}
dcycle() {  # dcycle <failing channels>: one dispatcher cycle; exit code in $H/rc, its log in $H/disp.err
  FAIL_CHANNELS="$1" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 bash "$MD" >/dev/null 2>"$H/disp.err"; echo $? > "$H/rc"
}
dsetup $'notify: {channels: {toast: false, ntfy: false}}'
dcycle ""; want_rc="$(cat "$H/rc")"; want_log="$(cat "$H/disp.err")"
dsetup $'notify: {channels: {toast: true, ntfy: true}, ntfy_topic: secret_topic_xyz}'
dcycle "toast"
has_dispatch_push="$(grep -c "^ntfy${T}shop · #9 waits for you" "$SENT")"
[ "$has_dispatch_push" = 1 ] && pass "AC-7 the dispatcher's cycle ends in a notification, and the push delivers" || fail "AC-7 expected the cycle to push '#9 waits for you' once, got $has_dispatch_push: $(cat "$SENT")"
[ "$(cat "$H/rc")" = "$want_rc" ] && pass "AC-7 the cycle's exit code is the one it has without notifications ($want_rc)" || fail "AC-7 exit code $(cat "$H/rc"), without notifications $want_rc"
got="$(grep -c 'shipfloor: notify: toast failed:' "$H/disp.err")"
[ "$got" = 1 ] && pass "AC-7 the failure is one line in the dispatcher's log" || fail "AC-7 expected one 'shipfloor: notify: toast failed:' line in the dispatcher's log, got $got: $(cat "$H/disp.err")"
rest="$(grep -v 'shipfloor: notify:' "$H/disp.err")"
[ "$rest" = "$want_log" ] && pass "AC-7 the rest of the log is what it is without notifications" || fail "AC-7 the log differs apart from the failure line: '$rest' vs '$want_log'"
case "$(cat "$H/disp.err")" in *secret_topic_xyz*) fail "AC-7 the dispatcher's log holds the topic" ;; *) pass "AC-7 the dispatcher's log never holds the topic" ;; esac
finish
