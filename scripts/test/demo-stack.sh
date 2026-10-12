#!/usr/bin/env bash
# The demo stack: the dashboard of this checkout served on sample data, so a card that changes the page can be
# looked at without a factory home. `demo-stack.sh up` prints http://127.0.0.1:<port>/?t=<token> once the page
# answers; `demo-stack.sh down` stops the server and removes everything `up` made.
#   SHIPFLOOR_STACK       the stack's name (default shipfloor-demo); names the state folder
#   SHIPFLOOR_PORT_WEB    the port (default 7727); another port than this one is a failure, the URL must be the known one
#   SHIPFLOOR_DEMO_TOKEN  the token (default demo)
# The state, ${TMPDIR:-/tmp}/shipfloor-demo/<name>/: home/ claude/ gh/ (the sample), server.log, pid.
# The server gets a home of its own and none of the caller's factory: it reads nothing of ~/.shipfloor and never
# calls the real gh. It holds none of the caller's files either (on Windows a server that held the output of
# `up` would keep the folder that stack_up logs to from being removed).
HERE="${BASH_SOURCE[0]%[/\\]*}"; HERE="$(cd "$HERE" && pwd)"
NAME="${SHIPFLOOR_STACK:-shipfloor-demo}"; PORT="${SHIPFLOOR_PORT_WEB:-7727}"; TOKEN="${SHIPFLOOR_DEMO_TOKEN:-demo}"
STATE="${TMPDIR:-/tmp}/shipfloor-demo/$NAME"
PY=python3; $PY -c '' 2>/dev/null || PY=python
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

alive() {  # alive <pid>: the process exists (the Windows pid in Git Bash)
  if command -v tasklist >/dev/null 2>&1; then tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -q "[[:space:]]$1[[:space:]]"
  else kill -0 "$1" 2>/dev/null; fi
}

ours() {  # ours <pid>: a pid file can outlive its server; where /proc says so, only a dashboard is stopped
  [ -e /proc/self/winpid ] || [ ! -r "/proc/$1/cmdline" ] || tr '\0' ' ' < "/proc/$1/cmdline" | grep -q 'dashboard.py'
}

stop() {  # stop <pid> and wait until it is gone
  local i win=0  # in Git Bash the pid is a Windows one: only taskkill knows it, kill would read it as an msys pid
  command -v taskkill >/dev/null 2>&1 && win=1
  for i in $(seq 1 50); do
    if [ "$i" -eq 1 ] || [ "$i" -eq 25 ]; then
      if [ "$win" -eq 1 ]; then taskkill //PID "$1" //F //T >/dev/null 2>&1
      elif [ "$i" -eq 1 ]; then kill "$1" 2>/dev/null
      else kill -9 "$1" 2>/dev/null; fi
    fi
    alive "$1" || return 0
    sleep 0.2
  done
  return 1
}

down() {
  local pid i
  [ -e "$STATE" ] || return 0
  pid="$(tr -d '\r\n ' < "$STATE/pid" 2>/dev/null)"
  if [ -n "$pid" ] && alive "$pid" && ours "$pid"; then
    stop "$pid" || { echo "demo-stack: the server $pid did not stop" >&2; return 1; }
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$STATE" 2>/dev/null; [ -e "$STATE" ] || return 0; sleep 0.3; done
  echo "demo-stack: cannot remove $STATE" >&2; return 1
}

fail() {  # fail <why>: the server's log, nothing left behind
  echo "demo-stack: $1" >&2
  tail -n 20 "$STATE/server.log" >&2 2>/dev/null
  down
  exit 1
}

up() {
  local pid winpid bash_n state_n url deadline
  down || exit 1
  mkdir -p "$STATE/user" || exit 1
  "$PY" -I "$(nat "$HERE/demo_home.py")" "$(nat "$STATE")" || fail "cannot build the sample"
  # an LF copy of the stand-in: a checkout with core.autocrlf gives demo-gh CRLF, which breaks its shebang and its split
  tr -d '\r' < "$HERE/demo-gh" > "$STATE/gh/demo-gh" && chmod +x "$STATE/gh/demo-gh" || fail "cannot copy the gh stand-in"
  bash_n="$(nat "$(command -v bash)")"; state_n="$(nat "$STATE")"
  (
    for v in $(compgen -v FACTORY_; compgen -v SHIPFLOOR_; compgen -v AGHANIM_); do unset "$v"; done
    export HOME="$STATE/user" USERPROFILE="$state_n/user"
    export SHIPFLOOR_HOME="$state_n/home" CLAUDE_CONFIG_DIR="$state_n/claude" SHIPFLOOR_BASH="$bash_n"
    export FACTORY_GH="$STATE/gh/demo-gh" SHIPFLOOR_DEMO_GH="$state_n/gh" SHIPFLOOR_DEMO_STATE="$state_n"
    export SHIPFLOOR_SCHEDULER="\"$bash_n\" -c 'echo \"\$1\" >> \"\$SHIPFLOOR_DEMO_STATE/scheduler.log\"' stub"
    exec "$PY" -I "$(nat "$HERE/../dashboard.py")" --home "$state_n/home" --port "$PORT" --token "$TOKEN" --no-open
  ) > "$STATE/server.log" 2>&1 < /dev/null &
  pid=$!; disown 2>/dev/null
  winpid="$(cat "/proc/$pid/winpid" 2>/dev/null)"; echo "${winpid:-$pid}" > "$STATE/pid"
  pid="${winpid:-$pid}"
  deadline=$((SECONDS + 30))
  until grep -q 'http://' "$STATE/server.log" 2>/dev/null; do
    alive "$pid" || fail "the server exited"
    [ "$SECONDS" -ge "$deadline" ] && fail "the server printed no address in 30 seconds"
    sleep 0.1
  done
  grep -q "http://127.0.0.1:$PORT/" "$STATE/server.log" || fail "the server did not get port $PORT"
  url="http://127.0.0.1:$PORT/"
  until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null)" = 200 ]; do
    alive "$pid" || fail "the server exited"
    [ "$SECONDS" -ge "$deadline" ] && fail "the page did not answer in 30 seconds"
    sleep 0.2
  done
  # the first overview asks gh for titles, labels and the board and bash for the stacks, a few seconds on Windows;
  # asked here, the page's first read (and a test's) finds them cached
  curl -s -o /dev/null --max-time 60 -H "X-Shipfloor-Token: $TOKEN" "${url}api/overview" 2>/dev/null
  echo "$url?t=$TOKEN"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: demo-stack.sh up|down" >&2; exit 2 ;;
esac
