#!/usr/bin/env bash
# Notifications when the factory needs the owner: what a dispatcher cycle tells (a card that waits, a reminder, the
# factory stuck, a card in production), once per wait. shipfloor_notify.py cycle reads the home the dispatcher
# leaves (board.tsv, the last health line, SKIPPED, PAUSE, config.yml) and hands each channel to
# SHIPFLOOR_NOTIFY_SEND as `<command> <channel> <title> <body>`; the test's sender records what it was handed.
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
[ -e "$(dirname "$0")/gh-fail" ] && { echo "gh: network error" >&2; exit 1; }
case "$*" in
  "issue list"*) echo '[{"number":7,"title":"Seven"},{"number":8,"title":"Eight"},{"number":9,"title":"Nine"},{"number":10,"title":"Ten"},{"number":11,"title":"Eleven"},{"number":12,"title":"Twelve"}]' ;;
  *) echo '[]' ;;
esac
EOF
  chmod +x "$H/send" "$H/gh"
  export SHIPFLOOR_NOTIFY_SEND="$(nat "$H/send")" FACTORY_GH="$(nat "$H/gh")"
  hl false
}
hl() {  # hl <usage_limited true|false> [blocked card numbers, comma separated]: the health line a cycle leaves
  printf '{"ts":"2026-10-11T10:00:00-03:00","paused":false,"usage_limited":%s,"projects":{"shop":{"paused":false,"skipped":false,"blocked":0,"blocked_cards":[%s]}}}\n' \
    "$1" "${2:-}" >> "$H/logs/health-2026-10.jsonl"
}
board() { printf '%b' "$1" > "$P/board.tsv"; }  # board '7\tSpec Review\tI7\n8\tStaged\tI8\n'
conf() { printf '%s\n' "$1" > "$H/config.yml"; }
cycle() {  # cycle <time>: one notifier cycle at that time (the machine's own clock, no zone)
  $PY -I "$(nat "$NOTIFY")" cycle --home "$(nat "$H")" --now "$1" >/dev/null 2>>"$H/err"
}
n_is() {  # n_is <want> <what>
  local got; got="$(grep -c '' "$SENT")"
  [ "$got" = "$1" ] && pass "$2" || fail "$2: expected $1 notification(s), got $got: $(tr '\n' ';' < "$SENT")"
}
has() {  # has <exact line: channel TAB title TAB body, lines joined by |> <what>
  grep -qxF -- "$1" "$SENT" && pass "$2" || fail "$2: expected '$1' in: $(tr '\n' ';' < "$SENT")"
}
has_part() {  # has_part <text one line must contain> <what>
  grep -qF -- "$1" "$SENT" && pass "$2" || fail "$2: expected a line with '$1' in: $(tr '\n' ';' < "$SENT")"
}
TOAST='notify: {channels: {toast: true}}'

# AC-1: a card that starts waiting for the owner (Spec Review, Staged, or a blocked run) is told once to each enabled
# channel with the project, number, title and state, and no later cycle tells that wait again
setup; conf $'notify: {channels: {toast: true, ntfy: true}, ntfy_topic: abc_123}'
board '7\tSpec Review\tI7\n8\tStaged\tI8\n9\tCoding\tI9\n10\tCoding\tI10\n'; hl false 9
cycle 2026-10-11T10:00:00
n_is 6 "AC-1 three waiting cards are told to two channels, once each"
for ch in toast ntfy; do
  has "${ch}${T}shop · #7 waits for you${T}Seven|Spec Review · spec to review" "AC-1 $ch: a spec to review"
  has "${ch}${T}shop · #8 waits for you${T}Eight|Staged · ready to ship" "AC-1 $ch: a card ready to ship"
  has "${ch}${T}shop · #9 is blocked${T}Nine|Stopped in develop" "AC-1 $ch: a blocked run names the stage it stopped in"
done
cycle 2026-10-11T10:05:00; cycle 2026-10-11T10:10:00
n_is 6 "AC-1 later cycles send no second notification for the same wait"
board '7\tReady for Dev\tI7\n8\tStaged\tI8\n9\tCoding\tI9\n10\tCoding\tI10\n'; cycle 2026-10-11T10:15:00
board '7\tSpec Review\tI7\n8\tStaged\tI8\n9\tCoding\tI9\n10\tCoding\tI10\n'; cycle 2026-10-11T10:20:00
n_is 8 "AC-1 a card that left its column and came back waits anew and is told again"

# AC-1: the blocked stage comes from the card's column
setup; conf "$TOAST"
board '7\tTechnical Refinement\tI7\n8\tValidation\tI8\n9\tReady for Prod\tI9\n'; hl false 7,8,9
cycle 2026-10-11T10:00:00
has "toast${T}shop · #7 is blocked${T}Seven|Stopped in refine" "AC-1 a block in Technical Refinement stopped in refine"
has "toast${T}shop · #8 is blocked${T}Eight|Stopped in validate" "AC-1 a block in Validation stopped in validate"
has "toast${T}shop · #9 is blocked${T}Nine|Stopped in deploy" "AC-1 a block in Ready for Prod stopped in deploy"

# AC-1: the copy follows the machine's language (one pt-BR check)
setup; conf $'language: pt-BR\nnotify: {channels: {toast: true}}'
board '7\tSpec Review\tI7\n'
cycle 2026-10-11T10:00:00
has_part "toast${T}shop · #7 espera você${T}Seven|" "AC-1 pt-BR: the title is in the machine's language, the card's title is not translated"

# AC-2: the reminder, once per wait, after the minutes the owner set
setup; conf $'notify: {channels: {toast: true}, reminder_min: 60}'
board '7\tSpec Review\tI7\n'
cycle 2026-10-11T10:00:00; cycle 2026-10-11T10:30:00; cycle 2026-10-11T10:59:00
n_is 1 "AC-2 before the 60 minutes there is only the first notification"
cycle 2026-10-11T11:00:00
n_is 2 "AC-2 at 60 minutes of waiting one reminder is sent"
has "toast${T}shop · #7 still waits for you${T}Seven|Spec Review · spec to review" "AC-2 the reminder repeats the first notification's body"
cycle 2026-10-11T11:01:00; cycle 2026-10-11T11:30:00; cycle 2026-10-11T13:00:00
n_is 2 "AC-2 the reminder is not sent again, not once per cycle"
setup; conf $'notify: {channels: {toast: true}, reminder_min: 15}'
board '8\tStaged\tI8\n'; cycle 2026-10-11T10:00:00; cycle 2026-10-11T10:14:00
n_is 1 "AC-2 a reminder of 15 minutes is not sent at 14"
cycle 2026-10-11T10:15:00
has "toast${T}shop · #8 still waits for you${T}Eight|Staged · ready to ship" "AC-2 a reminder of 15 minutes is sent at 15"

# AC-3: the factory is stuck: the usage limit, a skipped project, no card moving for an hour; each told once until
# the cause has cleared and come back
setup; conf "$TOAST"; board ''
hl true; cycle 2026-10-11T10:00:00; cycle 2026-10-11T10:05:00
n_is 1 "AC-3 the usage limit is told once"
has "toast${T}Shipfloor · the factory is stuck${T}The Claude usage limit was hit. New runs wait for it to reset." "AC-3 the usage limit copy"
hl false; cycle 2026-10-11T10:10:00; hl true; cycle 2026-10-11T10:15:00
n_is 2 "AC-3 the usage limit is told again once it has cleared and come back"

setup; conf "$TOAST"; board ''
printf '2026-10-11T09:00:00\tcannot bring the control checkout to origin/main: fatal: /secret/dir/.git/index.lock exists\n' > "$P/SKIPPED"
cycle 2026-10-11T10:00:00; cycle 2026-10-11T10:05:00
n_is 1 "AC-3 a skipped project is told once"
has "toast${T}shop · the factory is stuck${T}The dispatcher skips this project. The dashboard says why." "AC-3 a skipped project names the project and no reason"
rm "$P/SKIPPED"; cycle 2026-10-11T10:10:00
printf '2026-10-11T10:12:00\tinvalid .shipfloor/factory.yml on origin/main\n' > "$P/SKIPPED"; cycle 2026-10-11T10:15:00
n_is 2 "AC-3 a skip that clears and comes back is told again"

setup; conf "$TOAST"; board '12\tCoding\tI12\n'
cycle 2026-10-11T10:00:00; cycle 2026-10-11T10:30:00; cycle 2026-10-11T10:59:00
n_is 0 "AC-3 a card that sits less than an hour in the factory's columns is not stuck"
cycle 2026-10-11T11:01:00
n_is 1 "AC-3 no card moved for an hour while a card sits in a factory column"
has "toast${T}shop · the factory is stuck${T}No card moved for an hour and nothing is paused." "AC-3 the idle copy"
cycle 2026-10-11T11:30:00; cycle 2026-10-11T14:00:00
n_is 1 "AC-3 the idle cause is not told again while it holds"

setup; conf "$TOAST"; board '12\tCoding\tI12\n'
cycle 2026-10-11T10:00:00; board '12\tValidation\tI12\n'; cycle 2026-10-11T10:50:00; cycle 2026-10-11T11:30:00
n_is 0 "AC-3 a card that moved 40 minutes ago keeps the factory from being stuck"
cycle 2026-10-11T11:51:00
n_is 1 "AC-3 an hour after the last move the factory is stuck"

setup; conf "$TOAST"; board '12\tCoding\tI12\n'; touch "$P/PAUSE"
cycle 2026-10-11T10:00:00; cycle 2026-10-11T12:00:00
n_is 0 "AC-3 a paused project is not stuck"
setup; conf "$TOAST"; board '12\tCoding\tI12\n'; touch "$H/PAUSE"
cycle 2026-10-11T10:00:00; cycle 2026-10-11T12:00:00
n_is 0 "AC-3 a paused factory is not stuck"
setup; conf $'notify: {channels: {toast: true}, events: {reminder: false}}'; board '1\tInbox\tI1\n2\tDone\tI2\n3\tSpec Review\tI3\n'
cycle 2026-10-11T10:00:00; cycle 2026-10-11T12:00:00
n_is 1 "AC-3 cards outside the factory's columns are never stuck (only the one waiting for the owner is told)"
setup; conf $'notify: {channels: {toast: true}, events: {reminder: false}}'; board '12\tCoding\tI12\n'; hl false 12
cycle 2026-10-11T10:00:00; cycle 2026-10-11T12:00:00
n_is 1 "AC-3 a blocked card is told as blocked, not as a stuck factory"

# AC-4: a card that reaches Done is told only when the owner asked for it (off by default)
setup; conf "$TOAST"
board '8\tCoding\tI8\n9\tDone\tI9\n'; cycle 2026-10-11T10:00:00
board '8\tDone\tI8\n9\tDone\tI9\n'; cycle 2026-10-11T10:05:00
n_is 0 "AC-4 reached production is off by default"
setup; conf $'notify: {channels: {toast: true}, events: {done: true}}'
board '8\tCoding\tI8\n9\tDone\tI9\n'; cycle 2026-10-11T10:00:00
n_is 0 "AC-4 a card already in Done on the first cycle is not announced"
board '8\tDone\tI8\n9\tDone\tI9\n'; cycle 2026-10-11T10:05:00
n_is 1 "AC-4 a card that reached Done is told once"
has "toast${T}shop · #8 reached production${T}Eight" "AC-4 the copy has the number and the title"
cycle 2026-10-11T10:10:00
n_is 1 "AC-4 and not told again"
finish
