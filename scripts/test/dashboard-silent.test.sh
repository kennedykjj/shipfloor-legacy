#!/usr/bin/env bash
# suite: integration
# The factory that dies silently (#176): when the newest health line is older than 3x the dispatcher pace, the
# dashboard's overview carries "silent" and the page shows a banner with the status and reinstall commands.
# Every server here runs with SHIPFLOOR_SCHEDULER set to "none": a test never touches the real ShipfloorDispatcher task.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
C="$(mktemp -d)"; PIDS=""
trap 'kill $PIDS 2>/dev/null' EXIT
BASH_N="$(nat "$(command -v bash)")"

# fresh_home <every_min or ""> <minutes since the newest health line or "">
fresh_home() {
  H="$(mktemp -d)"; mkdir -p "$H/logs" "$H/projects/shop/logs" "$H/projects/shop/locks"
  printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$H/projects/shop/factory.yml"
  printf 'pool: 6\n' > "$H/config.yml"
  [ -n "$1" ] && printf 'dispatcher: {every_min: %s}\n' "$1" >> "$H/config.yml"
  if [ -n "$2" ]; then
    $PY -I -c 'import json,sys; from datetime import datetime,timedelta; t=(datetime.now().astimezone()-timedelta(minutes=float(sys.argv[1]))).isoformat(timespec="seconds"); print(json.dumps({"ts":t,"cycle":{"s":5,"exit":0,"overlap":False},"paused":False,"idle":[],"over":[]}))' "$2" >> "$H/logs/health-$(date +%Y-%m).jsonl"
  fi
}
start_dash() {
  SHIPFLOOR_SCHEDULER=none SHIPFLOOR_BASH="$BASH_N" FAKE_GH_NO_JQ=1 FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_DIR="$C" \
    $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$C/out-$1" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do grep -qs 'http://' "$C/out-$1" && break; sleep 0.1; done
  url="$(grep -o 'http://[^ ]*' "$C/out-$1")"; base="${url%%/?t=*}"; tok="${url##*t=}"
}
ov() { curl -s -H "X-Shipfloor-Token: $tok" "$base/api/overview"; }
# jget <json> <python expr on d>
jget() { printf '%s' "$1" | $PY -X utf8 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>&1 | tail -n 1; }
page_has() { if curl -s "$base/" | grep -qF -- "$1"; then pass "$2: the page carries '$1'"; else fail "$2: the page does not carry '$1'"; fi; }

# --- AC-1: 60 min without a cycle at pace 10 (threshold 30): the overview says so, with the commands
fresh_home 10 60; start_dash a
o="$(ov)"
got="$(jget "$o" '[int(d["silent"]["min"]), d["silent"]["every"]]')"
[ "$got" = "[60, 10]" ] && pass "AC-1 overview.silent has the age and the pace" || fail "AC-1 overview.silent min/every was: $got (want [60, 10]); overview: ${o:0:200}"
chk="$(jget "$o" 'd["silent"]["check"]')"; rei="$(jget "$o" 'd["silent"]["reinstall"]')"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    assert_contains "$chk" "Get-ScheduledTask -TaskName ShipfloorDispatcher"
    assert_contains "$rei" "install-dispatcher.ps1" ;;
  *)
    assert_contains "$chk" "install-dispatcher.sh --status"
    assert_contains "$rei" "install-dispatcher.sh"
    case "$rei" in *"--status"*) fail "AC-1 the reinstall command carries --status: $rei" ;; *) pass "AC-1 the reinstall command is not the status check" ;; esac ;;
esac
# the generic Health alert is suppressed for it: the banner is not shown twice
case "$(jget "$o" 'd["alerts"]')" in *"no dispatcher cycle"*) fail "AC-1 alerts still carries the silence line: $(jget "$o" 'd["alerts"]')" ;; *) pass "AC-1 alerts does not repeat the silence line" ;; esac
# the banner: a bad alert placed first among the alerts, with its parameters
page_has 'o?.silent' "AC-1"
page_has 't("alert.silent"' "AC-1"
page_has 't("alert.silent.text"' "AC-1"
pg="$(curl -s "$base/")"
a="${pg%%o?.silent*}"; b="${pg%%o?.paused*}"
[ "${#a}" -lt "${#b}" ] && [ "${#a}" -lt "${#pg}" ] && pass "AC-1 the silent banner is added before the other alerts" || fail "AC-1 the silent banner is not first in renderFlags"
case "$(echo "$pg" | grep -F 'o?.silent' | head -n 1)" in *'add("bad"'*) pass "AC-1 the banner is a bad alert" ;; *) fail "AC-1 the banner is not a bad alert" ;; esac
msg="$(en_msg alert.silent.text)"
for p in '{m}' '{every}' '{check}' '{reinstall}'; do
  case "$msg" in *"$p"*) pass "AC-1 alert.silent.text takes $p" ;; *) fail "AC-1 alert.silent.text lacks $p: '$msg'" ;; esac
done

# --- AC-3: within 3x (2x here) or no health line: no banner, no field
fresh_home 10 20; start_dash b
o="$(ov)"
[ "$(jget "$o" '"silent" in d and d["silent"] is None')" = True ] && pass "AC-3 at 2x the pace overview.silent is null" || fail "AC-3 overview.silent at 2x was: $(jget "$o" 'd.get("silent", "missing")')"
case "$(jget "$o" 'd["alerts"]')" in *"no dispatcher cycle"*) fail "AC-3 an alert at 2x the pace" ;; *) pass "AC-3 no silence alert at 2x the pace" ;; esac
fresh_home 10 ""; start_dash c
o="$(ov)"
[ "$(jget "$o" '"silent" in d and d["silent"] is None')" = True ] && pass "AC-3 with no health line overview.silent is null" || fail "AC-3 overview.silent with no line was: $(jget "$o" 'd.get("silent", "missing")')"

# --- AC-5: the pace of config.yml sets the threshold: 40 min is silent at pace 10, not at pace 15; no key falls back to 3
fresh_home 10 25; start_dash d
[ "$(jget "$(ov)" '"silent" in d and d["silent"] is None')" = True ] && pass "AC-5 25 min at pace 10 (threshold 30) is not silent" || fail "AC-5 25 min at pace 10 was: $(jget "$(ov)" 'd.get("silent", "missing")')"
fresh_home 10 40; start_dash f
[ "$(jget "$(ov)" 'd["silent"]["every"]')" = 10 ] && pass "AC-5 40 min at pace 10 (threshold 30) is silent, every 10" || fail "AC-5 40 min at pace 10 was: $(jget "$(ov)" 'd.get("silent", "missing")')"
fresh_home "" 12; start_dash e
[ "$(jget "$(ov)" 'd["silent"]["every"]')" = 3 ] && pass "AC-5 without the key the overview uses the default pace, 3" || fail "AC-5 default pace was: $(jget "$(ov)" 'd.get("silent", "missing")')"

# --- AC-4: both message keys exist, non-empty, in all 12 language files
n=0
for L in en pt-BR de es fr it ja ko ru tr zh-CN zh-TW; do
  n=$((n + 1))
  for k in alert.silent alert.silent.text; do
    [ -n "$(lang_msg "$L" "$k")" ] && pass "AC-4 $L has $k" || fail "AC-4 $L lacks $k"
  done
  # the placeholders survive translation
  m="$(lang_msg "$L" alert.silent.text)"
  for p in '{m}' '{every}' '{check}' '{reinstall}'; do
    case "$m" in *"$p"*) pass "AC-4 $L alert.silent.text keeps $p" ;; *) fail "AC-4 $L alert.silent.text lost $p" ;; esac
  done
done
[ "$n" = 12 ] && pass "AC-4 twelve languages checked" || fail "AC-4 checked $n languages"
finish
