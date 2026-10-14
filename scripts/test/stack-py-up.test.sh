#!/usr/bin/env bash
# #166 (PY-13), AC-3: up, down and the health probes (shipfloor_core/stack.py behind the lib/stack.sh shim). Each scenario
# runs in a fresh Shipfloor home and its record is checked: `down` before `up` with the new slot's env, up's output in
# up.log, the probes' timeout clamp(remaining, 1, 5), file:// URLs, the REJECT precedence, and the `up failed:` /
# `not healthy after Ts at <url>` messages. curl is a stub (it logs its arguments) except in the file:// scenario;
# lsof is a stub so no real process is touched.
source "$(dirname "$0")/lib.sh"
LIBTMP=("$FACTORY_HOME" "$SHIPFLOOR_HOME" "$REPO_TEMPLATE")
T="$(mktemp -d)" || exit 1; export TMPDIR="$T"
MAINPID=$$  # only this shell cleans up (a child that inherited the trap compares its parent's pid, not $BASHPID)
trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] || exit 0; rm -rf "$T" "${LIBTMP[@]}"' EXIT

mkdir -p "$T/rec"
stubs="$T/stubs"; curlstub="$T/curlstub"; mkdir -p "$stubs" "$curlstub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/lsof"
# curl stub: logs its arguments; $H/health.mode is fail (exit 22), fail-once (then ok) or body:<text>
cat > "$curlstub/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$H/curl.log"
mode="$(cat "$H/health.mode" 2>/dev/null)"
case "$mode" in
  fail) exit 22 ;;
  fail-once) echo "body:fine" > "$H/health.mode"; exit 7 ;;
  body:*) printf '%s\n' "${mode#body:}" ;;
esac
EOF
chmod +x "$stubs/lsof" "$curlstub/curl"
export PATH="$stubs:$PATH"

FIX="$FACTORY_DIR/test/fixture/factory.yml"
mkcfg() {  # mkcfg <file> <stack lines...>: the fixture with this stack section
  local f="$1"; shift
  sed '/^stack:/d' "$FIX" > "$f"; { echo "stack:"; printf '  %s\n' "$@"; } >> "$f"
}
DOWN="down: 'echo \"down slot=\$SHIPFLOOR_SLOT stack=\$SHIPFLOOR_STACK web=\$SHIPFLOOR_PORT_WEB url=\$SHIPFLOOR_STACK_URL pwd=\$PWD\" >> \"\$H/calls\"'"
{ i=1; while [ $i -le 30 ]; do echo "echo line $i"; i=$((i+1)); done; echo "echo boom >&2"; echo "exit 1"; } > "$T/up-fail.sh"
mkcfg "$T/upfail.yml" "up: 'bash $T/up-fail.sh'" "$DOWN" "ports: [web]" 'url: "http://localhost:{web}"'
mkcfg "$T/upok.yml" "up: 'echo up-out; echo up-err >&2; echo \"up slot=\$SHIPFLOOR_SLOT\" >> \"\$H/calls\"'" "$DOWN" "ports: [web, api]" \
  'url: "http://localhost:{web}/app"' 'health: "http://localhost:{api}/health"' "timeout: 3"
mkcfg "$T/sick.yml" "up: 'echo started'" "$DOWN" "ports: [web]" 'url: "http://localhost:{web}"' 'health: "http://localhost:{web}/health"' "timeout: 2"
mkcfg "$T/clamp.yml" "up: 'true'" "$DOWN" "ports: [web]" 'url: "http://localhost:{web}"' 'health: "http://localhost:{web}/h"' "timeout: 9"
mkcfg "$T/reject.yml" "up: 'echo started'" "$DOWN" "ports: [web]" 'url: "http://localhost:{web}"' 'health: "http://localhost:{web}/h"' 'reject: "Runtime Error|Exception"' "timeout: 1"
mkcfg "$T/badreject.yml" "up: 'true'" "$DOWN" "ports: [web]" 'url: "http://localhost:{web}"' 'health: "http://localhost:{web}/h"' 'reject: "a("' "timeout: 1"
mkcfg "$T/nohealth.yml" "up: 'true'" "$DOWN" "ports: [web]" 'url: "http://localhost:{web}"' 'reject: "anything"' "timeout: 1"
machine() { printf 'stacks: %s\nports: {base: 26100, span: 10}\nstack_wait: 3\nstack_stale: 90\nstack_hold_max: 2700\n' "$1" > "$SHIPFLOOR_HOME/config.yml"; }
dump() {  # the slot dirs with their files (beat.pid: only its presence), then the calls and curl logs
  local f
  (cd "$SHIPFLOOR_HOME" && find locks 2>/dev/null | LC_ALL=C sort) | while read -r f; do
    if [ -d "$SHIPFLOOR_HOME/$f" ]; then echo "[$f/]"
    else case "$f" in *beat.pid) echo "[$f] (pid)" ;; */env) echo "[$f]"; LC_ALL=C sort "$SHIPFLOOR_HOME/$f" ;; *) echo "[$f]"; cat "$SHIPFLOOR_HOME/$f"; echo ;; esac; fi
  done
  echo "[calls]"; cat "$H/calls" 2>/dev/null; rm -f "$H/calls"
}
up() {  # up <config> <owner>: stack_up in this shell; prints rc, stdout, stderr
  local rc; export FACTORY_CONFIG="$1"
  stack_up "$2" > "$H/out" 2> "$H/err"; rc=$?
  echo "stack_up $2: rc=$rc"; echo "--- stdout"; cat "$H/out"; echo "--- stderr"; cat "$H/err"
}
mvals() { echo "curl -m: $(sed -E 's/.*-m ([0-9]+).*/\1/' "$H/curl.log" 2>/dev/null | sort -un | tr '\n' ' ')"; }

scenario_upfail() { machine 1; up "$T/upfail.yml" failing; dump; }
scenario_upok() {  # slot 0 is someone else's: the down before up runs with slot 1's env
  machine 2; mkdir -p "$STACK_LOCKS/stack-0.lock"; echo "other - $(date +%s)" > "$STACK_LOCKS/stack-0.lock/info"; touch "$STACK_LOCKS/stack-0.lock/beat"
  PATH="$curlstub:$PATH"; echo "body:ok" > "$H/health.mode"
  up "$T/upok.yml" fine; echo "first probe: $(head -1 "$H/curl.log")"; dump
  stack_down fine; echo "down: $?"; dump
}
scenario_sick() {
  machine 1; PATH="$curlstub:$PATH"; echo fail > "$H/health.mode"
  up "$T/sick.yml" sick; echo "first probe: $(head -1 "$H/curl.log")"; mvals; dump
}
scenario_clamp() {
  machine 1; PATH="$curlstub:$PATH"; echo fail-once > "$H/health.mode"
  up "$T/clamp.yml" clamp; echo "first probe: $(head -1 "$H/curl.log")"; stack_down clamp; dump
}
scenario_reject() {
  machine 1; PATH="$curlstub:$PATH"; echo "body:500 Runtime Error at line 3" > "$H/health.mode"
  up "$T/reject.yml" rejected; dump
  echo "body:all good" > "$H/health.mode"; up "$T/reject.yml" accepted; stack_down accepted; dump
}
scenario_badreject() {
  machine 1; PATH="$curlstub:$PATH"; echo "body:x" > "$H/health.mode"
  up "$T/badreject.yml" bad 2>&1; stack_down bad; dump
}
scenario_nohealth() {
  machine 1; PATH="$curlstub:$PATH"
  up "$T/nohealth.yml" nohealth; echo "curl calls: $(cat "$H/curl.log" 2>/dev/null | wc -l | tr -d ' ')"; stack_down nohealth; dump
}
scenario_file() {  # the real curl on file:// URLs: missing, then there
  machine 1
  mkcfg "$H/file.yml" "up: 'true'" "$DOWN" "ports: [web]" 'url: "http://localhost:{web}"' "health: \"file://$H/health-{web}\"" "timeout: 1"
  up "$H/file.yml" nofile; dump
  echo ok > "$H/health-26100"; up "$H/file.yml" hasfile; stack_down hasfile; dump
}

norm() {  # norm <home>: the side's paths and epochs written out
  sed -E -e "s|$1|<H>|g" -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<E>\2/g'
}
run_side() {  # run_side <scenario>: its record in $T/rec/<scenario>.py
  local sc="$1" home="$T/py/$1"
  rm -rf "$home"; mkdir -p "$home/sh" "$home/w"
  ( export SHIPFLOOR_HOME="$home/sh" H="$home"; cd "$home/w" || exit 99
    source "$FACTORY_DIR/lib/project.sh"; source "$FACTORY_DIR/lib/stack.sh"; "scenario_$sc" ) > "$T/rec/$sc.py.raw" 2>&1
  echo "exit $?" >> "$T/rec/$sc.py.raw"
  norm "$home" < "$T/rec/$sc.py.raw" > "$T/rec/$sc.py"
}
has() {  # has <scenario> <label> <fixed string>: the Python record holds it
  grep -qF -- "$3" "$T/rec/$1.py" && pass "AC-3 $2" || fail "AC-3 $2: no '$3' in: $(cat "$T/rec/$1.py")"
}

for sc in upfail upok sick clamp reject badreject nohealth file; do run_side "$sc"; done
has upfail "an up that fails is exit 3" "stack_up failing: rc=3"
has upfail "up failed: the message then the tail" "stack: up failed:"
has upok "a healthy up prints the URL" "stack_up fine: rc=0
--- stdout
http://localhost:26110/app"
has upok "the down before up runs with the new slot's env" "down slot=1 stack=shipfloor-shop-1 web=26110"
has upok "up's output goes to up.log" "up-err"
has upok "the first probe uses the time left" "first probe: -fsS -m 3 http://localhost:26111/health"
has sick "a stack never healthy is exit 3" "stack_up sick: rc=3"
has sick "not healthy: the message" "stack: not healthy after 2s at http://localhost:26100/health"
has sick "the probe timeout is the time left, at least 1" "curl -m: 1 2 "
has clamp "a probe that fails once, then passes: healthy" "stack_up clamp: rc=0"
has clamp "a 9 s timeout probes with -m 5" "first probe: -fsS -m 5 http://localhost:26100/h"
has reject "a body matching REJECT is not healthy" "stack: not healthy after 1s at http://localhost:26100/h"
has reject "a body that does not match REJECT is healthy" "stack_up accepted: rc=0"
has badreject "a REJECT that grep -E refuses lets the stack through" "stack_up bad: rc=0"
has nohealth "no health URL: healthy at once, REJECT or not" "stack_up nohealth: rc=0"
has nohealth "no health URL: no probe" "curl calls: 0"
has file "a file:// URL that is not there is not healthy" "stack: not healthy after 1s at file://<H>/health-26100"
has file "a file:// URL that is there is healthy" "stack_up hasfile: rc=0"
finish
