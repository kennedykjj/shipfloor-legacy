#!/usr/bin/env bash
# The dashboard's "Notifications" settings: the machine config carries a notify block the API reads and writes
# (refusing invalid values with a sentence), the page has the section, and a saved change applies from the next
# dispatcher cycle.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
NOTIFY="$FACTORY_DIR/shipfloor_notify.py"
T=$'\t'
H="$(mktemp -d)"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$H/logs"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
SENT="$H/sent"; : > "$SENT"
cat > "$H/send" <<'EOF'
#!/usr/bin/env bash
body="${3//$'\n'/|}"; body="${body//$'\r'/}"
printf '%s\t%s\t%s\n' "$1" "$2" "$body" >> "$(dirname "$0")/sent"
exit 0
EOF
chmod +x "$H/send"
printf '{"ts":"2026-10-11T10:00:00-03:00","paused":false,"usage_limited":false,"projects":{"shop":{"paused":false,"skipped":false,"blocked":0,"blocked_cards":[]}}}\n' > "$H/logs/health-2026-10.jsonl"
export FAKE_GH_DIR="$(mktemp -d)" CLAUDE_CONFIG_DIR="$(nat "$(mktemp -d)")" SHIPFLOOR_BASH="$(nat "$(command -v bash)")" \
  FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 SHIPFLOOR_NOTIFY_SEND="$(nat "$H/send")"
board() { printf '%b' "$1" > "$P/board.tsv"; }
cycle() { $PY -I "$(nat "$NOTIFY")" cycle --home "$(nat "$H")" --now "$1" >/dev/null 2>>"$H/err"; }
n_is() {
  local got; got="$(grep -c '' "$SENT")"
  [ "$got" = "$1" ] && pass "$2" || fail "$2: expected $1 notification(s), got $got: $(tr '\n' ';' < "$SENT")"
}
has_part() { grep -qF -- "$1" "$SENT" && pass "$2" || fail "$2: expected a line with '$1' in: $(tr '\n' ';' < "$SENT")"; }

$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$FAKE_GH_DIR/out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$FAKE_GH_DIR/out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$FAKE_GH_DIR/out")"; base="${url%%/?t=*}"; tok="${url##*t=}"
H_TOK="X-Shipfloor-Token: $tok"
postb() {  # postb <json>: the body, then the status on the last line
  curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H "$H_TOK" -d "$1" "$base/api/settings/machine"; }
nget() { curl -s -H "$H_TOK" "$base/api/settings" | $PY -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["machine"]["notify"], sort_keys=True))' 2>/dev/null; }
refused() {  # refused <json> <sentence> <what>: 400 with that sentence, and the file as it was
  local before out; before="$(cat "$H/config.yml" 2>/dev/null)"; out="$(postb "$1")"
  if [ "${out##*$'\n'}" = 400 ] && [[ "$out" == *"$2"* ]]; then pass "$3"; else fail "$3: expected 400 and '$2', got: ${out:0:160}"; fi
  [ "$(cat "$H/config.yml" 2>/dev/null)" = "$before" ] && pass "$3 (nothing written)" || fail "$3: config.yml changed by a refused save"
}
accepted() { local out; out="$(postb "$1")"; [ "${out##*$'\n'}" = 200 ] && pass "$2" || fail "$2: expected 200, got: ${out:0:160}"; }

# AC-8: the API returns this machine's notification settings, with the defaults when config.yml has none
printf 'pool: 6\nlanguage: pt-BR\n' > "$H/config.yml"
DEFAULTS='{"channels": {"ntfy": false, "toast": true}, "events": {"blocked": true, "done": false, "reminder": true, "stuck": true, "waiting": true}, "ntfy_topic": "", "quiet": "", "reminder_min": 60}'
[ "$(nget)" = "$DEFAULTS" ] && pass "AC-8 GET /api/settings returns machine.notify with the defaults" || fail "AC-8 machine.notify: expected $DEFAULTS, got $(nget)"

# AC-8: a partial notify is merged key by key and the rest of config.yml stays
accepted '{"notify":{"events":{"done":true},"reminder_min":45}}' "AC-8 a partial notify is accepted"
want='{"channels": {"ntfy": false, "toast": true}, "events": {"blocked": true, "done": true, "reminder": true, "stuck": true, "waiting": true}, "ntfy_topic": "", "quiet": "", "reminder_min": 45}'
[ "$(nget)" = "$want" ] && pass "AC-8 the partial change is merged with what was there" || fail "AC-8 after a partial save expected $want, got $(nget)"
[[ "$(tr '\n' ' ' < "$H/config.yml")" == *"pool: 6"* && "$(tr '\n' ' ' < "$H/config.yml")" == *"language: pt-BR"* ]] && pass "AC-8 the rest of config.yml stays" || fail "AC-8 config.yml lost its other keys: $(cat "$H/config.yml")"
accepted '{"notify":{"ntfy_topic":"long_Random-topic_42","channels":{"ntfy":true},"quiet":"23:00-08:00"}}' "AC-8 a topic, the phone push and quiet hours are accepted"
accepted '{"notify":{"reminder_min":15}}' "AC-8 15 minutes is the shortest reminder"
accepted '{"notify":{"reminder_min":720}}' "AC-8 720 minutes is the longest reminder"
accepted '{"notify":{"quiet":""}}' "AC-8 empty quiet hours mean none"
accepted '{"notify":{"channels":{"ntfy":false},"ntfy_topic":""}}' "AC-8 the phone push goes off with its topic"

# AC-8: invalid values are refused with the spec's sentences and change nothing
refused '{"notify":{"reminder_min":14}}' "The reminder takes 15 to 720 minutes." "AC-8 a reminder under 15 minutes is refused"
refused '{"notify":{"reminder_min":721}}' "The reminder takes 15 to 720 minutes." "AC-8 a reminder over 720 minutes is refused"
refused '{"notify":{"reminder_min":"60"}}' "The reminder takes 15 to 720 minutes." "AC-8 a reminder that is not a number is refused"
refused '{"notify":{"quiet":"23:00-23:00"}}' "Quiet hours need both times, and they cannot be the same." "AC-8 quiet hours with the same ends are refused"
refused '{"notify":{"quiet":"23:00"}}' "Quiet hours need both times, and they cannot be the same." "AC-8 quiet hours with one time are refused"
refused '{"notify":{"ntfy_topic":"has space!"}}' "The topic takes letters, digits, - and _, up to 64." "AC-8 a topic with other characters is refused"
refused "{\"notify\":{\"ntfy_topic\":\"$(printf 'a%.0s' $(seq 1 65))\"}}" "The topic takes letters, digits, - and _, up to 64." "AC-8 a topic over 64 characters is refused"
accepted "{\"notify\":{\"ntfy_topic\":\"$(printf 'a%.0s' $(seq 1 64))\"}}" "AC-8 a topic of 64 characters is accepted"
accepted '{"notify":{"ntfy_topic":""}}' "AC-8 the topic is cleared"
out="$(postb '{"notify":{"channels":{"ntfy":true}}}')"
[ "${out##*$'\n'}" = 400 ] && pass "AC-8 the phone push cannot be on without a topic" || fail "AC-8 took the phone push on with no topic: ${out:0:160}"
out="$(postb '{"notify":{"events":{"waiting":"yes"}}}')"
[ "${out##*$'\n'}" = 400 ] && pass "AC-8 an event switch is a boolean" || fail "AC-8 took a non-boolean event: ${out:0:160}"
out="$(postb '{"notify":{"colour":"red"}}')"
[ "${out##*$'\n'}" = 400 ] && pass "AC-8 an unknown notify key is refused" || fail "AC-8 took an unknown notify key: ${out:0:160}"
out="$(postb '{"notify":{"events":{"launch":true}}}')"
[ "${out##*$'\n'}" = 400 ] && pass "AC-8 an unknown event is refused" || fail "AC-8 took an unknown event: ${out:0:160}"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"notify":{"reminder_min":30}}' "$base/api/settings/machine")"
[ "$code" = 403 ] && pass "AC-8 no token, no change" || fail "AC-8 changed the notification settings without the token (status $code)"

# AC-8: the Settings view has a "Notifications" section: events, channels, topic, reminder minutes, quiet hours
html="$(cat "$FACTORY_DIR/dashboard.html")"
for s in 'when the factory needs you' 'Events' 'Channels' 'Quiet hours' \
         'A card waits for your decision' 'A run is blocked' 'Remind me of a card that still waits' 'Minutes before the reminder' \
         'The factory is stuck' 'A card reached production' 'Windows notification on this machine' 'Push to your phone' 'ntfy topic' \
         'Set a topic to turn this on.' 'Windows only' 'No channel is on: nothing is sent.' 'Every event is off: nothing is sent.' \
         'type="time"' 'aria-invalid' 'The topic takes letters, digits, - and _, up to 64.' \
         'Quiet hours need both times, and they cannot be the same.' 'The reminder takes 15 to 720 minutes.'; do
  case "$html" in *"$s"*) pass "AC-8 the page has '$s'" ;; *) fail "AC-8 dashboard.html is missing '$s'" ;; esac
done
case "$html" in *'"Notifications"'*|*'>Notifications<'*|*'Notifications</'*) pass "AC-8 the Settings nav has a Notifications entry" ;; *) fail "AC-8 no Notifications entry in the Settings nav" ;; esac
echo "$html" | grep -Eq 'reminder_min.{0,120}720|720.{0,120}reminder_min' && pass "AC-8 the reminder stepper goes up to 720" || fail "AC-8 no reminder stepper bounded at 720"
$PY -I - "$(nat "$FACTORY_DIR/lang/dashboard.pt-BR.json")" <<'PYEOF' && pass "AC-8 the pt-BR catalog has the new phrases" || fail "AC-8 the pt-BR catalog lacks the Notifications phrases"
import json, sys
vals = set(json.load(open(sys.argv[1], encoding="utf-8"))["exact"].values())
want = ["Notificações", "Horário de silêncio", "Nenhum canal está ligado: nada é enviado.",
        "Todos os eventos estão desligados: nada é enviado.", "O lembrete aceita de 15 a 720 minutos."]
missing = [w for w in want if w not in vals]
sys.exit(print("missing:", missing) or 1 if missing else 0)
PYEOF
[ -f "$FACTORY_DIR/lang/notify.pt-BR.json" ] && pass "AC-8 the notification texts have a pt-BR catalog" || fail "AC-8 scripts/lang/notify.pt-BR.json does not exist"

# AC-8: a saved change applies from the next cycle; with every event or every channel off nothing is sent
printf 'pool: 6\n' > "$H/config.yml"; board ''
cycle 2026-10-11T10:00:00
accepted '{"notify":{"events":{"waiting":false,"blocked":false,"reminder":false,"stuck":false,"done":false}}}' "AC-8 every event switched off is saved"
board '8\tSpec Review\tI8\n'; cycle 2026-10-11T10:05:00
n_is 0 "AC-8 with every event off nothing is sent"
accepted '{"notify":{"events":{"waiting":true},"channels":{"toast":false}}}' "AC-8 every channel switched off is saved"
board '8\tSpec Review\tI8\n9\tStaged\tI9\n'; cycle 2026-10-11T10:10:00
n_is 0 "AC-8 with every channel off nothing is sent"
accepted '{"notify":{"channels":{"toast":true}}}' "AC-8 the toast switched on again is saved"
board '8\tSpec Review\tI8\n9\tStaged\tI9\n10\tStaged\tI10\n'; cycle 2026-10-11T10:15:00
has_part "toast${T}shop · #10 waits for you${T}" "AC-8 the saved change applies from the next cycle"
accepted '{"notify":{"events":{"waiting":false}}}' "AC-8 the waiting event switched off is saved"
board '8\tSpec Review\tI8\n9\tStaged\tI9\n10\tStaged\tI10\n11\tStaged\tI11\n'; cycle 2026-10-11T10:20:00
if grep -qF "shop · #11 waits for you" "$SENT"; then fail "AC-8 told a wait with the waiting event off"; else pass "AC-8 an event switched off stops its notifications"; fi
finish
