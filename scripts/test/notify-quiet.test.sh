#!/usr/bin/env bash
# Notifications in quiet hours: nothing is sent between the two times (this machine's clock), and the first cycle
# after them sends one notification listing what still needs the owner.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
NOTIFY="$FACTORY_DIR/shipfloor_notify.py"
T=$'\t'
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
  cat > "$H/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "issue list"*) echo '[{"number":7,"title":"Seven"},{"number":8,"title":"Eight"},{"number":9,"title":"Nine"},{"number":10,"title":"Ten"},{"number":11,"title":"Eleven"},{"number":12,"title":"Twelve"}]' ;;
  *) echo '[]' ;;
esac
EOF
  chmod +x "$H/send" "$H/gh"
  export SHIPFLOOR_NOTIFY_SEND="$(nat "$H/send")" FACTORY_GH="$(nat "$H/gh")"
  printf '{"ts":"2026-10-10T23:00:00-03:00","paused":false,"usage_limited":false,"projects":{"shop":{"paused":false,"skipped":false,"blocked":0,"blocked_cards":[]}}}\n' > "$H/logs/health-2026-10.jsonl"
}
board() { printf '%b' "$1" > "$P/board.tsv"; }
conf() { printf '%s\n' "$1" > "$H/config.yml"; }
cycle() { $PY -I "$(nat "$NOTIFY")" cycle --home "$(nat "$H")" --now "$1" >/dev/null 2>>"$H/err"; }
n_is() {
  local got; got="$(grep -c '' "$SENT")"
  [ "$got" = "$1" ] && pass "$2" || fail "$2: expected $1 notification(s), got $got: $(tr '\n' ';' < "$SENT")"
}
has() { grep -qxF -- "$1" "$SENT" && pass "$2" || fail "$2: expected '$1' in: $(tr '\n' ';' < "$SENT")"; }
# the reminder is off: a card waiting since 01:00 is 7 hours old at 08:00, and these tests are about the digest
QUIET=$'notify: {channels: {toast: true}, events: {reminder: false}, quiet: "23:00-08:00"}'

# AC-5: a card that starts waiting at 01:00 is held; the first cycle after 08:00 sends one notification for it
setup; conf "$QUIET"; board ''
cycle 2026-10-10T23:30:00
board '7\tSpec Review\tI7\n'
cycle 2026-10-11T01:00:00; cycle 2026-10-11T03:00:00; cycle 2026-10-11T07:59:00
n_is 0 "AC-5 nothing is sent before 08:00"
cycle 2026-10-11T08:00:00
n_is 1 "AC-5 the first cycle after the quiet hours sends one notification"
has "toast${T}Shipfloor · 1 card needs you${T}shop #7 Seven · Spec Review" "AC-5 the digest lists the card, its project, number, title and state"
cycle 2026-10-11T08:01:00; cycle 2026-10-11T09:00:00
n_is 1 "AC-5 the digest is not sent again"
board '7\tSpec Review\tI7\n8\tStaged\tI8\n'; cycle 2026-10-11T12:00:00
has "toast${T}shop · #8 waits for you${T}Eight|Staged · ready to ship" "AC-5 outside the quiet hours a new wait is told at once"

# AC-5: the digest lists the oldest wait first and the causes that still hold, one line each
setup; conf "$QUIET"; board ''
cycle 2026-10-10T23:30:00
board '7\tSpec Review\tI7\n'; cycle 2026-10-11T01:00:00
board '7\tSpec Review\tI7\n8\tStaged\tI8\n'
printf '2026-10-11T02:00:00\tcannot bring the control checkout to origin/main\n' > "$P/SKIPPED"; cycle 2026-10-11T02:00:00
n_is 0 "AC-5 a stuck cause is held in the quiet hours too"
cycle 2026-10-11T08:00:00
n_is 1 "AC-5 one digest for the cards and the cause"
has "toast${T}Shipfloor · 2 cards need you${T}shop #7 Seven · Spec Review|shop #8 Eight · Staged|shop · project skipped" "AC-5 oldest wait first, then the cause that still holds"

# AC-5: only causes: the digest says the factory is stuck
setup; conf "$QUIET"; board ''
cycle 2026-10-10T23:30:00
printf '2026-10-11T02:00:00\tcannot bring the control checkout to origin/main\n' > "$P/SKIPPED"; cycle 2026-10-11T02:00:00
cycle 2026-10-11T08:00:00
has "toast${T}Shipfloor · the factory is stuck${T}shop · project skipped" "AC-5 a digest of causes only"

# AC-5: at most 4 lines, then "and N more"
setup; conf "$QUIET"; board ''
cycle 2026-10-10T23:30:00
board '7\tSpec Review\tI7\n'; cycle 2026-10-11T00:10:00
board '7\tSpec Review\tI7\n8\tSpec Review\tI8\n'; cycle 2026-10-11T00:20:00
board '7\tSpec Review\tI7\n8\tSpec Review\tI8\n9\tSpec Review\tI9\n'; cycle 2026-10-11T00:30:00
board '7\tSpec Review\tI7\n8\tSpec Review\tI8\n9\tSpec Review\tI9\n10\tSpec Review\tI10\n'; cycle 2026-10-11T00:40:00
board '7\tSpec Review\tI7\n8\tSpec Review\tI8\n9\tSpec Review\tI9\n10\tSpec Review\tI10\n11\tSpec Review\tI11\n'; cycle 2026-10-11T00:50:00
board '7\tSpec Review\tI7\n8\tSpec Review\tI8\n9\tSpec Review\tI9\n10\tSpec Review\tI10\n11\tSpec Review\tI11\n12\tSpec Review\tI12\n'; cycle 2026-10-11T01:00:00
cycle 2026-10-11T08:00:00
n_is 1 "AC-5 six waiting cards are one notification"
has "toast${T}Shipfloor · 6 cards need you${T}shop #7 Seven · Spec Review|shop #8 Eight · Spec Review|shop #9 Nine · Spec Review|shop #10 Ten · Spec Review|and 2 more" "AC-5 four lines, then 'and 2 more'"

# AC-5: only what still needs the owner when the quiet hours end is listed; with nothing left, nothing is sent
# (stuck is off here: the decided card sits in Ready for Dev for hours, and the idle cause would hold by the spec)
setup; conf $'notify: {channels: {toast: true}, events: {reminder: false, stuck: false}, quiet: "23:00-08:00"}'; board ''
cycle 2026-10-10T23:30:00
board '7\tSpec Review\tI7\n'; cycle 2026-10-11T01:00:00
board '7\tReady for Dev\tI7\n'; cycle 2026-10-11T03:00:00
cycle 2026-10-11T08:00:00; cycle 2026-10-11T09:00:00
n_is 0 "AC-5 a card the owner already decided is not listed, and with nothing left nothing is sent"

# AC-5: "reached production" inside the quiet hours is dropped, not listed
setup; conf $'notify: {channels: {toast: true}, events: {done: true, reminder: false}, quiet: "23:00-08:00"}'
board '7\tCoding\tI7\n'; cycle 2026-10-10T23:30:00
board '7\tDone\tI7\n'; cycle 2026-10-11T02:00:00
cycle 2026-10-11T08:00:00; cycle 2026-10-11T09:00:00
n_is 0 "AC-5 a card that reached production in the quiet hours is dropped"
finish
