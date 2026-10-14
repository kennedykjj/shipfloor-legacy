#!/usr/bin/env bash
# shipfloor install puts every file in place in one step (a rename), so it is safe while runs are in progress.
# Each case has its own temporary SHIPFLOOR_HOME and its own copy of a small source tree; the real ~/.shipfloor is never touched.
source "$(dirname "$0")/lib.sh"
unset FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT
ROOT="$(cd "$(mktemp -d)" && pwd)"
BG=()
cleanup() { local p; for p in "${BG[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$ROOT" 2>/dev/null; }
trap cleanup EXIT

REAL_SHIPFLOOR="$FACTORY_DIR/shipfloor"; REAL_PROJECT="$FACTORY_DIR/lib/project.sh"; REALCP="$(command -v cp)"

check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$2: $3"; fi; }  # check <status> <name> <message when it failed>
same() { [ "$1" = "$2" ]; }

mk_v1() {  # mk_v1 <dir>: a small plugin tree (the real shipfloor, lib and Python package, synthetic scripts and templates)
  local d="$1"
  mkdir -p "$d/scripts/lib" "$d/scripts/old-dir" "$d/templates/old-sub" "$d/scripts/shipfloor_core"
  cp "$REAL_SHIPFLOOR" "$d/scripts/shipfloor"; cp "$REAL_PROJECT" "$d/scripts/lib/project.sh"; cp "$FACTORY_DIR/lib/py.sh" "$d/scripts/lib/py.sh"
  cp "$FACTORY_DIR/sf.py" "$d/scripts/sf.py"; cp "$FACTORY_DIR"/shipfloor_core/*.py "$d/scripts/shipfloor_core/"
  printf '#!/usr/bin/env bash\necho gate\n' > "$d/scripts/gate.sh"
  printf 'a v1\n' > "$d/scripts/zz-a.sh"; printf 'b v1\n' > "$d/scripts/lib/zz-b.sh"
  printf 'gone v1\n' > "$d/scripts/zz-gone.sh"; printf 'x v1\n' > "$d/scripts/old-dir/x.sh"
  printf 't1 v1\n' > "$d/templates/zz-t1.md"; printf 'tgone v1\n' > "$d/templates/zz-tgone.md"; printf 'y v1\n' > "$d/templates/old-sub/y.md"
}
mk_v2() {  # mk_v2 <from> <to>: 3 changed (zz-a.sh lib/zz-b.sh templates/zz-t1.md), 2 new, 4 no longer shipped
  cp -r "$1" "$2"
  printf 'a v2\n' > "$2/scripts/zz-a.sh"; printf 'b v2\n' > "$2/scripts/lib/zz-b.sh"; printf 't1 v2\n' > "$2/templates/zz-t1.md"
  printf 'new v2\n' > "$2/scripts/zz-new.sh"; printf 'tnew v2\n' > "$2/templates/zz-tnew.md"
  rm -rf "$2/scripts/zz-gone.sh" "$2/scripts/old-dir" "$2/templates/zz-tgone.md" "$2/templates/old-sub"
}
# The install is Python (shipfloor_core/cli.py) and calls no external cp, mv or rm: the faults are injected in the
# process. harness.py runs the source tree's `cli install` with os.replace, os.unlink and os.remove wrapped:
#   CALLS   a file that gets one line per rename (os.replace), the step that puts a file in place
#   KILL_AT the install dies at once (os._exit, nothing flushed or cleaned up) on that rename, before it happens
#   FAIL_FOR a rename whose target ends with this text is refused (PermissionError)
#   WATCH_FILE / WATCH_LOG  each rename and delete notes in WATCH_LOG when WATCH_FILE is missing at that moment
HARNESS="$ROOT/harness.py"
cat > "$HARNESS" <<'EOF'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
env = os.environ.get
kill_at, fail_for, watch = int(env("KILL_AT") or 0), env("FAIL_FOR") or "", env("WATCH_FILE") or ""
real = {"replace": os.replace, "unlink": os.unlink, "remove": os.remove}
count = [0]

def note(op, args):
    if watch and not os.path.isfile(watch):
        with open(env("WATCH_LOG") or os.devnull, "a") as f:
            f.write("missing when %s ran: %s\n" % (op, " ".join(map(str, args))))

def replace(src, dst, *a, **k):
    note("replace", (src, dst))
    count[0] += 1
    if env("CALLS"):
        with open(env("CALLS"), "a") as f:
            f.write("%s %s\n" % (src, dst))
    if kill_at and count[0] == kill_at:
        os._exit(137)
    if fail_for and str(dst).replace("\\", "/").endswith(fail_for):
        raise PermissionError(13, "refused to replace", str(dst))
    return real["replace"](src, dst, *a, **k)

def deleter(name):
    def f(path, *a, **k):
        note(name, (path,))
        return real[name](path, *a, **k)
    return f

os.replace, os.unlink, os.remove = replace, deleter("unlink"), deleter("remove")
from shipfloor_core import cli
sys.exit(cli.main(["install"]))
EOF

# inst <src> <home>: runs <src>/scripts/shipfloor install against that home; sets RC, OUT and ERR.
# With KILL_AT, FAIL_FOR or WATCH_FILE set, the same install runs through harness.py with that fault (CALLS: its log).
inst() {
  if [ -n "${KILL_AT:-}${FAIL_FOR:-}${WATCH_FILE:-}" ]; then
    SHIPFLOOR_HOME="$2" KILL_AT="${KILL_AT:-}" FAIL_FOR="${FAIL_FOR:-}" CALLS="${CALLS:-}" \
      WATCH_FILE="${WATCH_FILE:-}" WATCH_LOG="${WATCH_LOG:-}" \
      "$FACTORY_PYTHON" -I "$HARNESS" "$1/scripts" > "$ROOT/out" 2> "$ROOT/err"
  else
    SHIPFLOOR_HOME="$2" bash "$1/scripts/shipfloor" install > "$ROOT/out" 2> "$ROOT/err"
  fi
  RC=$?
  OUT="$(tr -d '\r' < "$ROOT/out")"; ERR="$(tr -d '\r' < "$ROOT/err")"
}
counts() { printf '%s\n' "$1" | sed -nE 's/^installed .*: ([0-9]+) replaced, ([0-9]+) added, ([0-9]+) removed$/\1 \2 \3/p' | tail -n 1; }
has_line() { printf '%s\n' "$1" | grep -Fxq -- "$2"; }
same_tree() {  # same_tree <src> <home>: the installed copy equals the source (what shipfloor doctor compares)
  diff -rq -x test -x .source -x templates "$1/scripts" "$2/factory" > "$ROOT/diff" 2>&1 \
    && diff -rq "$1/templates" "$2/factory/templates" >> "$ROOT/diff" 2>&1
}
whole() {  # whole <home> <srcA> <srcB>: every installed file is byte-equal to its version in A or in B; only .*.install-tmp may be extra
  local f rel base bad=""
  while IFS= read -r f; do
    rel="${f#"$1/factory/"}"; base="${rel##*/}"
    case "$base" in .source) continue ;; .*.install-tmp) continue ;; esac
    case "$rel" in
      templates/*) a="$2/$rel"; b="$3/$rel" ;;
      *) a="$2/scripts/$rel"; b="$3/scripts/$rel" ;;
    esac
    { [ -f "$a" ] && cmp -s "$f" "$a"; } || { [ -f "$b" ] && cmp -s "$f" "$b"; } || bad="$bad $rel"
  done < <(find "$1/factory" -type f)
  WHOLE_BAD="$bad"; [ -z "$bad" ]
}
tmp_left() { find "$1/factory" -type f -name '.*.install-tmp' | wc -l | tr -d ' '; }
doctor_matches() { SHIPFLOOR_HOME="$1" bash "$1/factory/shipfloor" doctor 2>&1 | tr -d '\r' | grep -q 'installed copy matches'; }
src_is() { [ -f "$1/factory/.source" ] && [ "$(cat "$1/factory/.source")" = "$(cd "$2" && pwd)" ]; }

# ---------------------------------------------------------------- AC-1
C="$ROOT/ac1"; H="$C/home"; S="$C/src"; mkdir -p "$C/run1" "$C/run2"; mk_v1 "$S"
cat > "$S/scripts/zz-long.sh" <<'EOF'
#!/usr/bin/env bash
: > "$1/started"
n=0
while [ ! -e "$1/go" ] && [ "$n" -lt 150 ]; do sleep 0.1; n=$((n+1)); done
echo old > "$1/out"
exit 0
EOF
inst "$S" "$H"
bash "$H/factory/zz-long.sh" "$C/run1" & LP=$!; BG+=("$LP")
for _ in $(seq 1 100); do [ -e "$C/run1/started" ] && break; sleep 0.1; done
[ -e "$C/run1/started" ] && pass "AC-1: the long-running script started" || fail "AC-1: the long-running script never started"
{
  echo '#!/usr/bin/env bash'
  for i in 1 2 3 4 5 6 7 8; do echo "# a second version of this script that is longer and has other text on every line ($i) ..........."; done
  echo 'echo new > "$1/out"'
  echo 'exit 0'
} > "$S/scripts/zz-long.sh"
inst "$S" "$H"
check "$RC" "AC-1: install over a running script exits 0" "exit $RC: $ERR"
: > "$C/run1/go"; wait "$LP"; LRC=$?
check "$LRC" "AC-1: the running script exits 0" "it exited $LRC (it read the new text in the middle of the old one)"
same "$(cat "$C/run1/out" 2>/dev/null)" old && pass "AC-1: the running script finished as the old version" \
  || fail "AC-1: the running script did not finish as the old version (out: '$(cat "$C/run1/out" 2>/dev/null)')"
: > "$C/run2/go"; bash "$H/factory/zz-long.sh" "$C/run2"
same "$(cat "$C/run2/out" 2>/dev/null)" new && pass "AC-1: the next start runs the new version" \
  || fail "AC-1: the next start did not run the new version (out: '$(cat "$C/run2/out" 2>/dev/null)')"

# ---------------------------------------------------------------- AC-2
C="$ROOT/ac2"; H="$C/home"; S="$C/src"; mkdir -p "$C"; mk_v1 "$S"
inst "$S" "$H"; check "$RC" "AC-2: first install exits 0" "exit $RC: $ERR"
(cd "$H/factory" && find . -type f -exec stat -c '%n %y' {} + | sort) > "$C/before"
inst "$S" "$H"
(cd "$H/factory" && find . -type f -exec stat -c '%n %y' {} + | sort) > "$C/after"
check "$RC" "AC-2: install of an unchanged source exits 0" "exit $RC: $ERR"
if cmp -s "$C/before" "$C/after"; then pass "AC-2: no installed file's modification time changed"
else fail "AC-2: modification times changed: $(diff "$C/before" "$C/after" | grep '^>' | tr '\n' ';')"; fi
same "$(counts "$OUT")" "0 0 0" && pass "AC-2: the output reports 0 replaced, 0 added, 0 removed" \
  || fail "AC-2: the output has no '0 replaced, 0 added, 0 removed' summary (got: '$(printf '%s' "$OUT" | grep '^installed')')"

# ---------------------------------------------------------------- AC-3
C="$ROOT/ac3"; H="$C/home"; S="$C/src"; mkdir -p "$C"; mk_v1 "$S"
yes 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' | head -n 3000 > "$C/refA"
yes 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' | head -n 3000 > "$C/refB"
cp "$C/refA" "$S/templates/zz-t1.md"
inst "$S" "$H"
reader() {  # reader <file> <log>: opens the template again and again until $C/stop exists
  local n=0
  while [ ! -e "$C/stop" ] && [ "$n" -lt 600 ]; do
    n=$((n+1))
    if ! "$REALCP" "$1" "$C/snap" 2>/dev/null; then echo "missing" >> "$2"; continue; fi
    cmp -s "$C/snap" "$C/refA" || cmp -s "$C/snap" "$C/refB" || echo "partial" >> "$2"
  done
  echo "$n" > "$2.count"
}
: > "$C/readlog"; reader "$H/factory/templates/zz-t1.md" "$C/readlog" & RP=$!; BG+=("$RP")
: > "$C/watchlog"
for i in 1 2 3 4 5 6; do
  if [ $((i % 2)) = 1 ]; then cp "$C/refB" "$S/templates/zz-t1.md"; else cp "$C/refA" "$S/templates/zz-t1.md"; fi
  WATCH_FILE="$H/factory/templates/zz-t1.md" WATCH_LOG="$C/watchlog" CALLS="$C/watchcalls" inst "$S" "$H"
  [ "$RC" = 0 ] || fail "AC-3: install $i exits $RC: $ERR"
done
: > "$C/stop"; wait "$RP"
[ -s "$C/watchcalls" ] && pass "AC-3: the watched installs put the template in place by rename" || fail "AC-3: the watched installs never renamed a file into place"
[ ! -s "$C/readlog" ] && pass "AC-3: the reader never found the template missing or partial" \
  || fail "AC-3: the reader saw $(sort "$C/readlog" | uniq -c | tr '\n' ' ') in $(cat "$C/readlog.count" 2>/dev/null) reads"
[ ! -s "$C/watchlog" ] && pass "AC-3: the installed template exists at every step of the install" \
  || fail "AC-3: the installed template was missing during the install: $(head -n 2 "$C/watchlog" | tr '\n' ';')"

# ---------------------------------------------------------------- AC-4
C="$ROOT/ac4"; H="$C/home"; S="$C/src"; mkdir -p "$C"; mk_v1 "$S"; mk_v2 "$S" "$C/B"
inst "$S" "$H"
[ -f "$H/factory/zz-gone.sh" ] && [ -f "$H/factory/templates/zz-tgone.md" ] && pass "AC-4: setup, the installed copy holds the files to be dropped" || fail "AC-4: setup, the first install did not install them"
inst "$C/B" "$H"
check "$RC" "AC-4: install exits 0" "exit $RC: $ERR"
[ ! -e "$H/factory/zz-gone.sh" ] && [ ! -e "$H/factory/old-dir/x.sh" ] && pass "AC-4: a script the plugin no longer ships is gone" || fail "AC-4: a script no longer shipped is still installed"
[ ! -e "$H/factory/templates/zz-tgone.md" ] && [ ! -e "$H/factory/templates/old-sub/y.md" ] && pass "AC-4: a template the plugin no longer ships is gone" || fail "AC-4: a template no longer shipped is still installed"
[ ! -d "$H/factory/old-dir" ] && [ ! -d "$H/factory/templates/old-sub" ] && pass "AC-4: directories left empty are removed" || fail "AC-4: an empty directory was left behind"
same_tree "$C/B" "$H" && pass "AC-4: every shipped file is present and equal" || fail "AC-4: the installed copy differs from the source: $(tr '\n' ';' < "$ROOT/diff")"

# ---------------------------------------------------------------- AC-6 (counts) and the leftovers
C="$ROOT/ac6"; H="$C/home"; S="$C/src"; mkdir -p "$C"; mk_v1 "$S"; mk_v2 "$S" "$C/B"
inst "$S" "$H"
: > "$H/factory/.zz-a.sh.install-tmp"; : > "$H/factory/templates/.zz-t1.md.install-tmp"
inst "$C/B" "$H"
check "$RC" "AC-6: install exits 0" "exit $RC: $ERR"
same "$(counts "$OUT")" "3 2 4" && pass "AC-6: 3 replaced, 2 added, 4 removed, each equal to the real count" \
  || fail "AC-6: want '3 replaced, 2 added, 4 removed' as the summary, got: '$(printf '%s' "$OUT" | grep '^installed')'"
last2="$(printf '%s\n' "$OUT" | tail -n 2)"
case "$last2" in "installed "*"
next: "*) pass "AC-6: the summary line is followed by the next: line" ;; *) fail "AC-6: stdout should end with the installed line and then next:, got: $last2" ;; esac
[ "$(tmp_left "$H")" = 0 ] && pass "AC-6: leftover temporary files are deleted by the install" || fail "AC-6: a leftover .install-tmp file survived the install"
same_tree "$C/B" "$H" && pass "AC-6: the installed copy equals the source" || fail "AC-6: the installed copy differs: $(tr '\n' ';' < "$ROOT/diff")"

# ---------------------------------------------------------------- AC-5 and AC-7: an install killed halfway
C="$ROOT/ac5"; H="$C/home"; S="$C/src"; mkdir -p "$C"; mk_v1 "$S"; mk_v2 "$S" "$C/B"
inst "$S" "$H"; SRC_BEFORE="$(cat "$H/factory/.source")"
CALLS="$C/calls" KILL_AT=2 inst "$C/B" "$H"
[ -s "$C/calls" ] && pass "AC-5: the install puts files in place by rename" || fail "AC-5: the install never renamed a file into place (os.replace): $ERR"
[ "$RC" != 0 ] && pass "AC-5: the killed install did not exit 0" || fail "AC-5: the install was not killed (exit 0)"
if whole "$H" "$S" "$C/B"; then pass "AC-5: every installed file is byte-equal to its old or new version"
else fail "AC-5: files neither old nor new (or a temporary file taken for a script):$WHOLE_BAD"; fi
same "$(cat "$H/factory/.source")" "$SRC_BEFORE" && pass "AC-7: .source is unchanged after the killed install" \
  || fail "AC-7: .source names $(cat "$H/factory/.source") after a killed install, was $SRC_BEFORE"
doctor_matches "$H" && fail "AC-7: doctor reports the copy matches after a killed install" || pass "AC-7: doctor does not report that the copy matches"
inst "$C/B" "$H"
check "$RC" "AC-5: a second install exits 0" "exit $RC: $ERR"
same_tree "$C/B" "$H" && pass "AC-5: the second install leaves the copy equal to the source" || fail "AC-5: the copy differs from the source after the second install: $(tr '\n' ';' < "$ROOT/diff")"
[ "$(tmp_left "$H")" = 0 ] && pass "AC-5: no temporary file is left after the second install" || fail "AC-5: a .install-tmp file is left after the second install"
src_is "$H" "$C/B" && pass "AC-7: .source names the source once everything is in place" || fail "AC-7: .source does not name the source after the second install"
doctor_matches "$H" && pass "AC-7: doctor reports the copy matches after the second install" || fail "AC-7: doctor does not report a match after the second install"

# a first install killed halfway leaves no .source at all
C="$ROOT/ac7first"; H="$C/home"; mkdir -p "$C"; mk_v1 "$C/A"
CALLS="$C/calls" KILL_AT=2 inst "$C/A" "$H"
[ -s "$C/calls" ] && [ ! -e "$H/factory/.source" ] && pass "AC-7: a first install killed halfway leaves no .source" \
  || fail "AC-7: .source exists after a first install that was killed (or no file was renamed into place): $ERR"
inst "$C/A" "$H"
check "$RC" "AC-7: the install after a killed first one exits 0" "exit $RC: $ERR"
src_is "$H" "$C/A" && same_tree "$C/A" "$H" && pass "AC-7: it completes the copy and writes .source" || fail "AC-7: the copy is not complete after the install that followed"

# ---------------------------------------------------------------- AC-8 (and AC-7): a file that cannot be replaced
C="$ROOT/ac8"; H="$C/home"; S="$C/src"; mkdir -p "$C"; mk_v1 "$S"; mk_v2 "$S" "$C/B"
inst "$S" "$H"; SRC_BEFORE="$(cat "$H/factory/.source")"
CALLS="$C/calls" FAIL_FOR="/lib/zz-b.sh" inst "$C/B" "$H"
[ -s "$C/calls" ] && pass "AC-8: the install puts files in place by rename" || fail "AC-8: the install never renamed a file into place, so it cannot name a file it could not replace: $ERR"
[ "$RC" = 1 ] && pass "AC-8: exits 1 when a file could not be replaced" || fail "AC-8: exit $RC, want 1 when a file could not be replaced"
has_line "$ERR" "shipfloor: could not replace lib/zz-b.sh" && pass "AC-8: stderr names the file that could not be replaced" \
  || fail "AC-8: stderr lacks 'shipfloor: could not replace lib/zz-b.sh' (stderr: '$ERR')"
same "$(cat "$H/factory/zz-a.sh")" "a v2" && same "$(cat "$H/factory/zz-new.sh" 2>/dev/null)" "new v2" && same "$(cat "$H/factory/templates/zz-t1.md")" "t1 v2" \
  && pass "AC-8: the other files are still installed" || fail "AC-8: the other files were not installed after one could not be replaced"
same "$(cat "$H/factory/lib/zz-b.sh")" "b v1" && pass "AC-8: the file that could not be replaced is whole (old version)" || fail "AC-8: lib/zz-b.sh is not the old version"
[ "$(tmp_left "$H")" = 0 ] && pass "AC-8: no temporary file is left for the file that failed" || fail "AC-8: a .install-tmp file is left behind"
same "$(cat "$H/factory/.source")" "$SRC_BEFORE" && pass "AC-7: .source is unchanged when a file could not be replaced" \
  || fail "AC-7: .source changed to $(cat "$H/factory/.source") although a file could not be replaced"
doctor_matches "$H" && fail "AC-7: doctor reports the copy matches although a file is not in place" || pass "AC-7: doctor does not report a match while a file is not in place"
inst "$C/B" "$H"
check "$RC" "AC-8: a later install, with the file free, exits 0" "exit $RC: $ERR"
same_tree "$C/B" "$H" && src_is "$H" "$C/B" && pass "AC-8: the later install completes the copy and .source" || fail "AC-8: the later install left the copy incomplete: $(tr '\n' ';' < "$ROOT/diff")"

# a file held open by another process, Git Bash on Windows only: the rename may be refused or not, the outcome must be consistent
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    C="$ROOT/ac8held"; H="$C/home"; S="$C/src"; mkdir -p "$C"; mk_v1 "$S"; mk_v2 "$S" "$C/B"
    inst "$S" "$H"
    nat() { cygpath -m "$1"; }
    "${FACTORY_PYTHON:-python}" -c 'import sys,time; f=open(sys.argv[1],"rb"); open(sys.argv[2],"w").close(); time.sleep(60)' "$(nat "$H/factory/zz-a.sh")" "$(nat "$C/ready")" & HP=$!; BG+=("$HP")
    for _ in $(seq 1 100); do [ -e "$C/ready" ] && break; sleep 0.1; done
    if [ -e "$C/ready" ]; then
      inst "$C/B" "$H"
      if [ "$RC" = 0 ]; then
        same "$(cat "$H/factory/zz-a.sh")" "a v2" && src_is "$H" "$C/B" && pass "AC-8: a held file replaced by rename, exit 0, .source written" || fail "AC-8: exit 0 but the held file or .source is not in place"
      else
        has_line "$ERR" "shipfloor: could not replace zz-a.sh" && [ "$RC" = 1 ] && same "$(cat "$H/factory/lib/zz-b.sh")" "b v2" && ! src_is "$H" "$C/B" \
          && pass "AC-8: a held file is named, the others installed, exit 1, .source left alone" \
          || fail "AC-8: held file refused (exit $RC) but the output is not as specified (stderr: '$ERR')"
      fi
      kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
      inst "$C/B" "$H"
      check "$RC" "AC-8: once the held file is free the install exits 0" "exit $RC: $ERR"
      same_tree "$C/B" "$H" && src_is "$H" "$C/B" && pass "AC-8: and the copy equals the source" || fail "AC-8: the copy is incomplete after the file was freed"
    else
      fail "AC-8: python never opened the file to hold it"
    fi ;;
esac

finish
