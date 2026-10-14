#!/usr/bin/env bash
# The Python port of board.sh and setup-board.sh (#163):
#   AC-6  the wrappers hold no logic (they only source lib/py.sh and exec), and on Linux `board.sh status <n>` with a
#         snapshot is at most 100 ms slower than the Bash version. The existing board*.test.sh, dispatch-order,
#         dashboard*.test.sh and PY-08 tests passing unedited are proved by the suite itself.
source "$(dirname "$0")/lib.sh"

# ---- hygiene: the two scripts are wrappers
for w in board setup-board; do
  f="$FACTORY_DIR/$w.sh"
  code="$(grep -vE '^[[:space:]]*(#|$)' "$f" | tr -d '\r')"
  n="$(printf '%s\n' "$code" | grep -c .)"
  t="AC-6 $w.sh is a wrapper"
  [ "$n" -le 6 ] && pass "$t: $n lines of code" || fail "$t: $n lines of code, want at most 6"
  srcs="$(printf '%s\n' "$code" | grep -E '(^|[;&|[:space:]])(source|\.)[[:space:]]' | tr -d '\r')"
  case "$srcs" in
    *lib/py.sh*) pass "$t: sources lib/py.sh" ;;
    *) fail "$t: does not source lib/py.sh" ;;
  esac
  other="$(printf '%s\n' "$srcs" | grep -vF 'lib/py.sh')"
  [ -z "$other" ] && pass "$t: sources nothing else" || fail "$t: sources $other"
  logic="$(printf '%s\n' "$code" | grep -E '(^|[^A-Za-z_])(if|case|for|while|until|function|shipfloor_[a-z]+|gh|awk|sed|grep|cut|mapfile|read)([^A-Za-z_]|$)|\(\)[[:space:]]*\{|FACTORY_GH|GH=' )"
  [ -z "$logic" ] && pass "$t: no logic in it" || fail "$t: has logic: $(printf '%s' "$logic" | head -3)"
  case "$code" in *"$w"*) pass "$t: names its command ($w)" ;; *) fail "$t: does not name sf.py's $w command" ;; esac
  [ -x "$f" ] && pass "$t: is executable" || fail "$t: has no execute bit"
done

# ---- timing (Linux only): the wrapper may cost at most 100 ms more than the Bash version
if [ "$(uname -s)" = Linux ]; then
  cfg="$FACTORY_CONFIG"
  snap="$(mktemp)"; printf '25\tSpec Review\tI25\n33\tCoding\tI33\n' > "$snap"
  ref="$(mktemp -d)/board-ref.sh"   # the Bash board.sh's `status` path as it was: resolve, three config values, the check, the awk
  cat > "$ref" <<EOF
#!/usr/bin/env bash
set -uo pipefail
HERE="$FACTORY_DIR"
source "\$HERE/lib/project.sh"
shipfloor_resolve . || exit 2
mapfile -d '' -t V < <(shipfloor_cfg values board.owner board.number project.repo 2>/dev/null)
[ "\${#V[@]}" -eq 3 ] || exit 2
[[ "\${V[0]}" =~ ^[A-Za-z0-9-]+\$ && "\${V[1]}" =~ ^[0-9]+\$ ]] || exit 2
cat "\$FACTORY_BOARD_SNAPSHOT" | awk -F'\t' -v n="\$1" '\$1==n{print \$2}'
EOF
  now_ms() { local t; t="$(date +%s%N)"; echo $((t / 1000000)); }
  median() {  # median <script> <runs>: median of the wall-clock times, in ms
    local s="$1" runs="$2" i a b ts=()
    for i in $(seq 1 "$runs"); do
      a="$(now_ms)"; FACTORY_BOARD_SNAPSHOT="$snap" FACTORY_CONFIG="$cfg" bash "$s" status 33 >/dev/null 2>&1; b="$(now_ms)"
      ts+=("$((b - a))")
    done
    printf '%s\n' "${ts[@]}" | sort -n | sed -n "$(( (runs + 1) / 2 ))p"
  }
  out="$(FACTORY_BOARD_SNAPSHOT="$snap" bash "$FACTORY_DIR/board.sh" status 33 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = Coding ] && pass "AC-6 board.sh status 33 with a snapshot prints Coding" || fail "AC-6 board.sh status 33 → exit $rc, '$out'"
  bash "$ref" status 33 >/dev/null 2>&1 || true
  base="$(median "$ref" 15)"; port="$(median "$FACTORY_DIR/board.sh" 15)"
  diff=$((port - base))
  [ "$diff" -le 100 ] && pass "AC-6 board.sh status is ${diff} ms slower than the Bash version (limit 100): ${port} ms vs ${base} ms" \
    || fail "AC-6 board.sh status is ${diff} ms slower than the Bash version (limit 100): ${port} ms vs ${base} ms"
else
  pass "AC-6 timing check is Linux only"
fi
finish
