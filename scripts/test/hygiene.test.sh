#!/usr/bin/env bash
# Nothing the plugin ships names its first project, its owner or one machine's paths.
source "$(dirname "$0")/lib.sh"
root="$FACTORY_DIR/.."
hits="$(cd "$root" && grep -rIniE 'pickio|kennedykjj|/c/Users|scripts/factory|PICKIO_FACTORY' \
  skills agents scripts templates installer examples README.md .claude-plugin 2>/dev/null | grep -v '^scripts/test/' \
  | grep -v '^scripts/dashboard.html:.*href="https://github.com/kennedykjj/shipfloor#learn-more"' || true)"  # the dashboard's Docs link: Shipfloor's own home
[ -z "$hits" ] && pass "no project- or machine-specific references" || fail "found:
$hits"
for a in backend-engineer frontend-engineer; do
  [ ! -e "$root/agents/$a.md" ] && pass "no $a agent in the plugin" || fail "agents/$a.md still shipped"
done
[ -f "$root/skills/validate/SKILL.md" ] && pass "validate stage" || fail "skills/validate missing"
[ -f "$root/agents/engineer.md" ] && pass "generic engineer agent" || fail "agents/engineer.md missing"
[ -f "$root/examples/factory.yml" ] && pass "example config" || fail "examples/factory.yml missing"
assert_exit 0 env FACTORY_CONFIG="$root/examples/factory.yml" bash "$FACTORY_DIR/shipfloor-config.sh" validate
# The renames left no live old name: only lines marked "legacy aghanim" or "legacy mylos" may carry one.
stale="$(cd "$root" && grep -rIniE 'mylos|aghanim' skills agents scripts templates installer examples README.md .claude-plugin .gitattributes 2>/dev/null   | grep -v '^scripts/test/' | grep -vE 'legacy (aghanim|mylos)' || true)"
[ -z "$stale" ] && pass "no stale old-name references" || fail "stale old name:
$stale"
# AC-7: the old names stay only as the dashboard's old-log readers: a "legacy aghanim" / "legacy mylos" marker
# is accepted in scripts/dashboard.py and scripts/dashboard_cost.py and nowhere else
marked="$(cd "$root" && grep -rIniE 'legacy (aghanim|mylos)' skills agents scripts templates installer examples README.md docs/install.md .claude-plugin .gitattributes 2>/dev/null | grep -v '^scripts/test/' | grep -vE '^scripts/(dashboard|dashboard_cost)\.py:' || true)"
[ -z "$marked" ] && pass "AC-7 legacy markers only in the dashboard's old-log readers" || fail "AC-7 legacy marker outside scripts/dashboard.py and scripts/dashboard_cost.py:
$marked"
for f in scripts/dashboard.py scripts/dashboard_cost.py; do
  grep -qE 'legacy (aghanim|mylos)' "$root/$f" && pass "AC-7 $f keeps its old-log reader" || fail "AC-7 $f lost its legacy marker"
done
# AC-4: the Windows installer neither looks up nor removes the old scheduled task
if grep -qi 'AghanimDispatcher' "$root/installer/install-dispatcher.ps1"; then fail "AC-4 install-dispatcher.ps1 still names AghanimDispatcher: $(grep -ni 'AghanimDispatcher' "$root/installer/install-dispatcher.ps1")"; else pass "AC-4 the installer does not touch AghanimDispatcher"; fi
# AC-5: the install guide and the README have no upgrade section and no migrate-home
for f in docs/install.md README.md; do
  if grep -qiE 'Upgrading from Aghanim' "$root/$f"; then fail "AC-5 $f still has the Aghanim upgrade section"; else pass "AC-5 $f has no Aghanim upgrade section"; fi
  if grep -q 'migrate-home' "$root/$f"; then fail "AC-5 $f still mentions migrate-home"; else pass "AC-5 $f does not mention migrate-home"; fi
done
# a test run from inside a factory run does not see that factory
out="$(FACTORY_HOME=/real FACTORY_CONFIG=/real/factory.yml SHIPFLOOR_HOME=/real SHIPFLOOR_STACK=x bash -c 'source "$1/test/lib.sh"; echo "$FACTORY_HOME $FACTORY_CONFIG $SHIPFLOOR_HOME ${SHIPFLOOR_STACK-unset}"' _ "$FACTORY_DIR")"
case "$out" in */real*) fail "a test inherited the factory: $out" ;; *unset) pass "tests drop an inherited factory" ;; *) fail "inherited stack: $out" ;; esac
grep -q "^# Shipfloor" "$root/README.md" && pass "README carries the brand" || fail "README title"
# The factory runs its scripts directly ("$BOARD" snapshot): Linux and macOS need the execute bit that Windows ignores
noexec=""
for f in "$root"/scripts/*.sh "$root/scripts/shipfloor"; do [ -x "$f" ] || noexec="$noexec ${f#"$root"/}"; done
[ -z "$noexec" ] && pass "the factory's scripts are executable" || fail "not executable (git update-index --chmod=+x):$noexec"

# AC-1: git, not the disk, is what an install copies: every .sh in scripts/ and scripts/lib/ is mode 100755 in the index
badmode=""
while read -r mode _ _ path; do
  rest="${path#scripts/}"; [ "$rest" != "$path" ] || continue
  name="${rest#lib/}"; case "$name" in */*) continue ;; *.sh) ;; *) continue ;; esac
  [ "$mode" = 100755 ] || badmode="$badmode ${path} ($mode)"
done < <(git -C "$root" ls-files -s -- scripts)
[ -z "$badmode" ] && pass "AC-1 every scripts/*.sh and scripts/lib/*.sh is mode 100755 in git" || fail "AC-1 not 100755 in git (git update-index --chmod=+x):$badmode"

# AC-1: an installed board.sh without the execute bit is still run: dispatch.sh and deploy.sh call it through bash
nobit="$(plugin_copy)"; stub_board="$(mktemp -d)"
cat > "$nobit/scripts/board.sh" <<'EOB'
#!/usr/bin/env bash
echo "$1" >> "$BOARD_CALLS"
case "$1" in status) exit 1 ;; count) echo 0 ;; esac
exit 0
EOB
chmod 644 "$nobit/scripts/board.sh"
export BOARD_CALLS="$stub_board/calls"; : > "$BOARD_CALLS"
(
  export SHIPFLOOR_HOME="$(mktemp -d)"; export FACTORY_HOME="$SHIPFLOOR_HOME/projects/shop" FACTORY_CONTROL_REFRESH=0 FACTORY_WT_ROOT="$(mktemp -d)" FACTORY_PROJECT=shop
  export FACTORY_CONFIG="$FACTORY_DIR/test/fixture/factory.yml"; unset FACTORY_BOARD
  mkdir -p "$FACTORY_HOME/control"
  bash "$nobit/scripts/dispatch.sh" > "$stub_board/dispatch.out" 2>&1; echo $? > "$stub_board/dispatch.rc"
  bash "$nobit/scripts/deploy.sh" 7 > "$stub_board/deploy.out" 2>&1; echo $? > "$stub_board/deploy.rc"
)
[ "$(cat "$stub_board/dispatch.rc")" = 0 ] && pass "AC-1 dispatch.sh runs with a board.sh that lacks the execute bit" || fail "AC-1 dispatch.sh exit $(cat "$stub_board/dispatch.rc"): $(cat "$stub_board/dispatch.out")"
assert_contains "$(cat "$BOARD_CALLS")" "snapshot"
assert_contains "$(cat "$BOARD_CALLS")" "status"
case "$(cat "$stub_board/dispatch.out" "$stub_board/deploy.out")" in *"Permission denied"*|*"cannot execute"*) fail "AC-1 the board was run directly: $(cat "$stub_board/dispatch.out" "$stub_board/deploy.out")" ;; *) pass "AC-1 no permission error from the board call" ;; esac

grep -q 'report.json schema' "$root/scripts/report.sh" && pass "AC-8 report.sh keeps the report.json schema header" || fail "AC-8 report.sh lost its schema header"

# #189 AC-1 / AC-3: no skill or agent tells the agent to run the GraphQL-backed gh commands (file and line named on failure)
gqlhits="$(cd "$root" && find skills -name '*.md' -type f | sort | xargs -r grep -nE 'gh +(issue|pr (view|checks|comment))' 2>/dev/null; grep -nE 'gh +(issue|pr (view|checks|comment))' agents/*.md 2>/dev/null || true)"
[ -z "$gqlhits" ] && pass "#189 AC-1 no skill or agent names gh issue / gh pr view|checks|comment" || fail "#189 AC-1 GraphQL gh command in a skill or agent (use the REST form):
$gqlhits"
[ -z "$gqlhits" ] && pass "#189 AC-3 the scan finds no forbidden command (file:line reported otherwise)" || fail "#189 AC-3 forbidden command at file:line:
$gqlhits"

# #189 AC-2: the skills that did those operations spell out the REST form (or name the factory script)
refine="$(cat "$root/skills/refine/SKILL.md")"; validate="$(cat "$root/skills/validate/SKILL.md")"
needs() { # <label> <text> <needle>
  case "$2" in *"$3"*) pass "#189 AC-2 $1 names $3" ;; *) fail "#189 AC-2 $1 lacks $3" ;; esac
}
needs "refine (comment)" "$refine" 'gh api repos/'
needs "refine (comment)" "$refine" 'issues/<n>/comments'
needs "refine (label)" "$refine" 'issues/<n>/labels'
needs "refine (label)" "$refine" 'labels[]=blocked'
needs "validate (PR read)" "$validate" 'gh api repos/'
needs "validate (PR read)" "$validate" 'pulls/<pr>'
needs "validate (PR read)" "$validate" '.mergeable'
needs "validate (checks)" "$validate" 'commits/<sha>/check-runs'
needs "validate (checks)" "$validate" '.head.sha'
needs "validate (PR/issue comment)" "$validate" 'issues/<n>/comments'
needs "validate (issue read)" "$validate" 'board.sh issue'

# ---- #171 (PY-18): every script is a wrapper or a shim; the logic is the Python package
# AC-1/AC-2: test/fixtures/wrapper-check.py reads scripts/*.sh, scripts/shipfloor and scripts/lib/*.sh of a root and
# prints one "<file>: <why>" line per line of logic it finds (nothing when they are all wrappers and shims)
WCHECK="$FACTORY_DIR/test/fixtures/wrapper-check.py"
wcheck() { "$FACTORY_PYTHON" -I "$WCHECK" "$1"; }
if [ -f "$WCHECK" ]; then
  found="$(wcheck "$root" 2>&1)"
  [ -z "$found" ] && pass "AC-1/AC-2 every scripts/*.sh, scripts/shipfloor and scripts/lib/*.sh is a wrapper or a shim" || fail "AC-1/AC-2 logic left in the scripts:
$found"
else
  fail "AC-1/AC-2 no test/fixtures/wrapper-check.py"
fi

# AC-3: one line of logic added to any wrapper, fast path or shim of a copy is caught, and the file is named
wcopy() {  # wcopy: a copy of the files the check reads; prints its root
  local d; d="$(mktemp -d)"; mkdir -p "$d/scripts/lib"
  cp "$root"/scripts/*.sh "$root/scripts/shipfloor" "$d/scripts/"; cp "$root"/scripts/lib/*.sh "$d/scripts/lib/"
  echo "$d"
}
caught() {  # caught <label> <file under scripts/> <python edit of the text s>: the check names the file once edited
  local d; d="$(wcopy)"
  "$FACTORY_PYTHON" -I -c 'import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
exec(sys.argv[2])
open(p, "w", encoding="utf-8").write(s)' "$d/scripts/$2" "$3" "${4:-}"
  case "$(wcheck "$d" 2>&1)" in *"$2: "*) pass "AC-3 $1 is caught ($2)" ;; *) fail "AC-3 $1 in $2 passed the check" ;; esac
}
LOGIC='if [ -n "${X:-}" ]; then exit 9; fi'
if [ -f "$WCHECK" ]; then
  for f in "$root"/scripts/*.sh "$root/scripts/shipfloor"; do
    f="${f##*/}"
    # the line goes before the last line of code: the wrapper's source line, the fast path's own last line
    caught "a line of logic" "$f" "i = s.rstrip(chr(10)).rfind(chr(10)) + 1; s = s[:i] + sys.argv[3] + chr(10) + s[i:]" "$LOGIC"
  done
  for f in "$root"/scripts/lib/*.sh; do
    caught "a top-level line of logic" "lib/${f##*/}" "s = s + sys.argv[3] + chr(10)" '[ -n "${X:-}" ] && exit 9'
  done
  caught "control flow in a one-line function" lib/project.sh "s = s + 'shipfloor_x() { if true; then _shipfloor_sf x; fi; }' + chr(10)"
  caught "a line inside the pinned Python lookup" lib/project.sh "s = s.replace('  export SHIPFLOOR_PY', '  [ -x \"\$SHIPFLOOR_PY\" ] || exit 9' + chr(10) + '  export SHIPFLOOR_PY', 1)"
  caught "a line inside the pinned signal forwarding" lib/stack.sh "s = s.replace('  _STACK_CHILD=\$!', '  _STACK_CHILD=\$!; [ -n \"\$X\" ] && exit 9', 1)"
  caught "a line in the launcher" lib/py.sh "s = s.replace('export SHIPFLOOR_PY', '[ -n \"\$X\" ] && exit 9' + chr(10) + 'export SHIPFLOOR_PY', 1)"
  caught "an extra command in the step fast path" shipfloor-config.sh "s = s.replace('  exit 0', '  echo step' + chr(10) + '  exit 0', 1)"
  caught "a grep in a wrapper's export" board.sh "s = s.replace('set -- board', 'export X=\"\$(grep -c . /dev/null)\"' + chr(10) + 'set -- board', 1)"
fi

# AC-5: nothing under scripts/ but test/ (and the lang/ catalogs) starts awk or jq; sed only for the catalog and grep only
# for the ERE helpers, both in shipfloor_core/text.py
tools="$("$FACTORY_PYTHON" -I - "$root" <<'PY'
import os, re, sys
S = os.path.join(sys.argv[1], "scripts")
SH = re.compile(r"(^|[\s;|&(`])(awk|gawk|sed|jq|grep|egrep|fgrep)(?=[\s;|&)]|$)")
ARGV = re.compile(r"([\"'])(awk|gawk|sed|jq|grep|egrep|fgrep)\1")
for d, dirs, files in os.walk(S):
    rel = os.path.relpath(d, S).replace(os.sep, "/")
    if rel.split("/")[0] in ("test", "lang") or "__pycache__" in rel:
        dirs[:] = []
        continue
    for f in sorted(files):
        p = os.path.join(d, f)
        r = os.path.normpath(os.path.join(rel, f)).replace(os.sep, "/")
        text = open(p, encoding="utf-8", errors="replace").read().split("\n")
        if f.endswith(".sh") or f == "shipfloor":
            for n, l in enumerate(text, 1):
                c = re.sub(r"(^|\s)#.*$", "", l)
                if SH.search(c):
                    print("%s:%d: %s" % (r, n, l.strip()))
        elif f.endswith(".py") and r != "shipfloor_core/text.py":
            for n, l in enumerate(text, 1):
                if ARGV.search(l):
                    print("%s:%d: %s" % (r, n, l.strip()))
PY
)"
[ -z "$tools" ] && pass "AC-5 no awk or jq; sed and grep only in shipfloor_core/text.py (the catalog and the ERE helpers)" || fail "AC-5 a text tool started outside shipfloor_core/text.py:
$tools"
grep -q '"sed"' "$root/scripts/shipfloor_core/text.py" && grep -q '"grep"' "$root/scripts/shipfloor_core/text.py" \
  && pass "AC-5 the catalog and the ERE helpers are still in shipfloor_core/text.py" || fail "AC-5 shipfloor_core/text.py no longer starts sed or grep"

# AC-9: the commit trailer, the deploy defaults and the stage/column table are defined once, in shipfloor_core/defaults.py
once="$("$FACTORY_PYTHON" -I - "$root" <<'PY'
import os, re, sys
S = os.path.join(sys.argv[1], "scripts")
FACTS = {"the commit trailer": (re.compile(r"Co-Authored-By:"), None),
         "the deploy defaults": (re.compile(r'timeout_min"?\W{1,4}30\b|conflict_max_files"?\W{1,4}5\b|V\[4\] or "30"|V\[5\] or "5"'), None),
         "the stage/column table": (re.compile(r'"Ready for (Refinement|Dev|Prod)"'), ("shipfloor_health.py", "shipfloor_core/dispatch.py"))}
hits = {k: [] for k in FACTS}
for d, dirs, files in os.walk(S):
    rel = os.path.relpath(d, S).replace(os.sep, "/")
    if rel.split("/")[0] in ("test", "lang") or "__pycache__" in rel:
        dirs[:] = []
        continue
    for f in files:
        if not (f.endswith(".py") or f.endswith(".sh") or f == "shipfloor"):
            continue
        r = os.path.normpath(os.path.join(rel, f)).replace(os.sep, "/")
        text = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
        for k, (rx, only) in FACTS.items():
            if (only is None or r in only or r == "shipfloor_core/defaults.py") and rx.search(text):
                hits[k].append(r)
for k, files in hits.items():
    print("%s\t%s" % (k, " ".join(sorted(files))))
PY
)"
while IFS=$'\t' read -r what files; do
  [ "$files" = shipfloor_core/defaults.py ] && pass "AC-9 $what is defined once, in shipfloor_core/defaults.py" || fail "AC-9 $what is written in: ${files:-nowhere}"
done <<< "$once"
for m in "shipfloor_core.deploy TRAILER TRAILER" "shipfloor_core.report TRAILER TRAILER" "shipfloor_health STAGES STAGES"; do
  set -- $m
  "$FACTORY_PYTHON" -I -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import importlib
m = importlib.import_module(sys.argv[2]); from shipfloor_core import defaults
sys.exit(0 if getattr(m, sys.argv[3]) is getattr(defaults, sys.argv[4]) else 1)' "$root/scripts" "$1" "$2" "$3" 2>/dev/null \
    && pass "AC-9 $1.$2 is shipfloor_core.defaults.$3" || fail "AC-9 $1.$2 is not taken from shipfloor_core.defaults"
done
# The suite's size is a budget: a card extends the module's existing suite instead of adding a file per criterion.
# 167 files on main when this ceiling came in (182 with the factory PRs then open); diet pass 2 (#236-#239 and the
# small modules) brought it to 46. The owner lowers the ceiling as files go, and never raises it to fit a new file.
ceiling=52  # 46 after wave 2; #223, #227, #240, #245 and visual-v4 landed, #234 folded dashboard-settings into dashboard-views to fit
count="$(cd "$root" && ls scripts/test/*.test.sh | wc -l | tr -d ' ')"
[ "$count" -le "$ceiling" ] && pass "test files: $count, ceiling $ceiling" || fail "scripts/test has $count *.test.sh files, the ceiling is $ceiling: extend an existing suite of the module instead of adding a file"
finish
