#!/usr/bin/env bash
# shipfloor demo (card #175): a fake card crosses the factory with no real repo, no network and no LLM.
# Isolation: HOME and SHIPFLOOR_HOME are temp dirs holding a sentinel tree that is hashed before and after; gh and claude
# on PATH fail and log; TMPDIR is private, so "the temporary home" is whatever the demo leaves in it.
source "$(dirname "$0")/lib.sh"
PY="$FACTORY_PYTHON"
T="$(mktemp -d)"; SF="$FACTORY_DIR/shipfloor"; README="$FACTORY_DIR/../README.md"
PIDS=""
cleanup() { [ -n "$PIDS" ] && kill $PIDS 2>/dev/null; exec 3<&- 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 300"
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1: got '$2', want '$3'"; }
has() { printf '%s\n' "$2" | grep -qiE -- "$3" && pass "$1" || fail "$1: no line matches /$3/ in: $(printf '%s' "$2" | head -c 600)"; }
lineno() { printf '%s\n' "$1" | grep -niE -m1 -- "$2" | cut -d: -f1; }  # first line number matching, empty when none

# a real-looking home with a sentinel tree, and a gh and a claude that fail and leave a trace
export HOME="$T/home"; mkdir -p "$HOME/.shipfloor/projects/real" "$HOME/.claude"
echo "keep me" > "$HOME/.shipfloor/projects/real/state.json"; echo "cfg" > "$HOME/.shipfloor/config.yml"
export SHIPFLOOR_HOME="$HOME/.shipfloor"; export USERPROFILE="$HOME"
BIN="$T/bin"; mkdir -p "$BIN"
for b in gh claude; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/called"\necho "no network, no LLM" >&2\nexit 1\n' "$b" "$T" > "$BIN/$b"; chmod +x "$BIN/$b"
done
export PATH="$BIN:$PATH"
hash_tree() { (cd "$HOME" && find . -type f -print0 | sort -z | xargs -0 sha256sum; find . -print | sort) 2>/dev/null | sha256sum | cut -d' ' -f1; }
BEFORE="$(hash_tree)"

# run_demo <tag> <stdin file> [args]: private TMPDIR, no browser; sets RC, OUT, TD (the private TMPDIR)
run_demo() {
  local tag="$1" in="$2"; shift 2
  TD="$T/tmp-$tag"; mkdir -p "$TD"
  if [ ! -f "$SF" ]; then RC=127; OUT="$SF does not exist"; return; fi
  START=$SECONDS
  TMPDIR="$TD" TMP="$TD" TEMP="$TD" BROWSER=true $TMO bash "$SF" demo "$@" < "$in" > "$T/out-$tag" 2> "$T/err-$tag"
  RC=$?; ELAPSED=$((SECONDS - START))
  OUT="$(tr -d '\r' < "$T/out-$tag"; tr -d '\r' < "$T/err-$tag")"
}
: > "$T/empty"

# --- AC-1, AC-3, AC-5, AC-6, AC-8 (--no-dashboard): one run, without the dashboard
run_demo main "$T/empty" --no-dashboard
eq "AC-1 'shipfloor demo --no-dashboard' exits 0 (last lines: $(printf '%s' "$OUT" | tail -n 3 | tr '\n' '|'))" "$RC" "0"
[ "$RC" = 0 ] && [ "$ELAPSED" -le 300 ] && pass "AC-1 it finished in ${ELAPSED}s, inside the 5-minute limit" || fail "AC-1 took ${ELAPSED}s or failed"
[ ! -e "$T/called" ] && pass "AC-1 neither gh nor claude on PATH was ever called (no network, no LLM)" || fail "AC-1 the PATH tools were called: $(head -n 3 "$T/called")"

# AC-3: the real ~/.shipfloor (and all of HOME) is unchanged
eq "AC-3 the sentinel home is byte-for-byte the same afterwards" "$(hash_tree)" "$BEFORE"
[ "$RC" = 0 ] && pass "AC-3 the demo ran, so the unchanged home is not a no-op" || fail "AC-3 the demo did not run"

# AC-5: narration, in order
for stage in refine develop validate deploy; do has "AC-5 the narration names the $stage column" "$OUT" "$stage"; done
r="$(lineno "$OUT" 'refine')"; d="$(lineno "$OUT" 'develop')"; v="$(lineno "$OUT" 'validate')"; p="$(lineno "$OUT" 'deploy')"
[ -n "$r" ] && [ -n "$d" ] && [ -n "$v" ] && [ -n "$p" ] && [ "$r" -le "$d" ] && [ "$d" -le "$v" ] && [ "$v" -le "$p" ] && pass "AC-5 refine, develop, validate, deploy appear in that order" || fail "AC-5 stage order: $r $d $v $p"
red="$(lineno "$OUT" '\bred\b')"; green="$(lineno "$OUT" '\bgreen\b')"
[ -n "$red" ] && [ -n "$green" ] && [ "$red" -lt "$green" ] && pass "AC-5 the red gate is narrated before the green gate" || fail "AC-5 red line '$red', green line '$green'"
has "AC-5 the red gate is narrated as a gate verdict" "$OUT" '(gate.*\bred\b|\bred\b.*gate)'
has "AC-5 the green gate is narrated as a gate verdict" "$OUT" '(gate.*\bgreen\b|\bgreen\b.*gate)'
has "AC-5 one block going to the owner is narrated" "$OUT" 'block.*owner|owner.*block'
n="$(printf '%s\n' "$OUT" | grep -ciE 'approv')"
[ "$n" -ge 2 ] && pass "AC-5 two owner approvals are narrated ($n lines)" || fail "AC-5 approval lines: $n (want 2 or more)"
b="$(lineno "$OUT" 'block')"; a="$(lineno "$OUT" 'approv')"
[ -n "$b" ] && [ -n "$a" ] && [ "$b" -le "$a" ] && pass "AC-5 the block comes before the approvals" || fail "AC-5 block line '$b', first approval line '$a'"

# AC-6: plain words, at the start and when a run is shown
has "AC-6 the banner says no LLM ran" "$(printf '%s\n' "$OUT" | head -n 12)" 'no LLM ran'
has "AC-6 the banner says the runs are recorded transcripts" "$(printf '%s\n' "$OUT" | head -n 12)" 'recorded transcripts'
n="$(printf '%s\n' "$OUT" | grep -ciE 'no LLM ran|recorded transcript')"
[ "$n" -ge 2 ] && pass "AC-6 the statement is repeated past the banner ($n lines)" || fail "AC-6 the statement appears $n time(s) (want 2 or more: the banner and the first run line)"

# AC-8 / AC-7: without --keep the temporary home is gone
eq "AC-8 --no-dashboard leaves no temporary home behind" "$(find "$TD" -mindepth 1 2>/dev/null | head -n 3 | tr '\n' ' ')" ""
[ "$RC" = 0 ] && ! printf '%s\n' "$OUT" | grep -qE 'http://127\.0\.0\.1' && pass "AC-8 --no-dashboard prints no dashboard URL" || fail "AC-8 --no-dashboard printed a dashboard URL, or the demo failed"

# --- AC-8: --keep leaves the temporary home in place and prints its path
run_demo keep "$T/empty" --no-dashboard --keep
eq "AC-8 --keep exits 0 (last lines: $(printf '%s' "$OUT" | tail -n 3 | tr '\n' '|'))" "$RC" "0"
KEPT="$(find "$TD" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)"
[ -n "$KEPT" ] && [ -d "$KEPT" ] && pass "AC-8 --keep left a temporary home in place" || fail "AC-8 --keep left nothing in $TD"
[ -n "$KEPT" ] && has "AC-8 --keep prints the path of the temporary home" "$OUT" "$(printf '%s' "$KEPT" | sed 's/[][\.*^$/]/\\&/g')"
eq "AC-8 the real home is still unchanged after --keep" "$(hash_tree)" "$BEFORE"
rm -rf "$TD"

# --- AC-7: no flags: the dashboard is opened on the temporary home, waits for Enter, then the home is deleted
TD="$T/tmp-dash"; mkdir -p "$TD"; FIFO="$T/stdin.fifo"
if mkfifo "$FIFO" 2>/dev/null && [ -f "$SF" ]; then
  exec 3<>"$FIFO"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/browser"\n' "$T" > "$BIN/opener"; chmod +x "$BIN/opener"
  TMPDIR="$TD" TMP="$TD" TEMP="$TD" BROWSER="$BIN/opener %s" $TMO bash "$SF" demo < "$FIFO" > "$T/out-dash" 2> "$T/err-dash" &
  DPID=$!; PIDS="$PIDS $DPID"
  for _ in $(seq 1 3000); do grep -qs 'http://' "$T/out-dash" && break; kill -0 "$DPID" 2>/dev/null || break; sleep 0.1; done
  URL="$(grep -o 'http://[^ ]*' "$T/out-dash" 2>/dev/null | head -n 1 | tr -d '\r')"
  [ -n "$URL" ] && pass "AC-7 the demo printed the dashboard URL ($URL)" || fail "AC-7 no dashboard URL printed: $(tr -d '\r' < "$T/out-dash" 2>/dev/null | tail -n 3)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null)"
  eq "AC-7 the dashboard answers while the demo waits" "$code" "200"
  [ -n "$(find "$TD" -mindepth 1 2>/dev/null | head -n 1)" ] && pass "AC-7 the temporary home exists while the dashboard is up" || fail "AC-7 no temporary home while the dashboard is up"
  echo > "$FIFO"
  wait "$DPID"; DRC=$?
  eq "AC-7 the demo exits 0 after Enter" "$DRC" "0"
  eq "AC-7 the temporary home is deleted at the end" "$(find "$TD" -mindepth 1 2>/dev/null | head -n 3 | tr '\n' ' ')" ""
  [ -n "$URL" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL" 2>/dev/null)" != "200" ] && pass "AC-7 the dashboard is stopped at the end" || fail "AC-7 the dashboard still answers, or there was no URL"
  [ -s "$T/browser" ] && pass "AC-7 the browser opener was asked to open the dashboard" || fail "AC-7 the browser opener was never called"
  exec 3<&-
else
  fail "AC-7 cannot run: no fifo, or no shipfloor script"
fi
eq "AC-7 the real home is unchanged after the dashboard run" "$(hash_tree)" "$BEFORE"
[ ! -e "$T/called" ] && pass "AC-7 neither gh nor claude on PATH was called in any run" || fail "AC-7 the PATH tools were called: $(head -n 3 "$T/called")"

# --- AC-4: the README points to the demo before the quick start
RD="$(tr -d '\r' < "$README")"
q="$(lineno "$RD" '^#+ .*quick start')"; t="$(lineno "$RD" 'try it.*shipfloor demo')"
[ -n "$t" ] && pass "AC-4 the README has a 'Try it: shipfloor demo' line" || fail "AC-4 no 'Try it: shipfloor demo' line in the README"
[ -n "$q" ] && [ -n "$t" ] && [ "$t" -lt "$q" ] && pass "AC-4 the line (at $t) is before Quick start (at ${q})" || fail "AC-4 Try-it line '$t', Quick start heading '$q'"

# --- AC-2: the same test is the CI test: portable (no GNU-only flags beyond the ones the other tests use), runs on every OS of the matrix
[ -f "$FACTORY_DIR/test/demo.test.sh" ] && pass "AC-2 demo.test.sh is in scripts/test, where the suite runs it on each OS" || fail "AC-2 demo.test.sh is missing"
finish
