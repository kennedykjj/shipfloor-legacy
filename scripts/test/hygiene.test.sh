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

# AC-8 (#164): report.sh, metrics.sh and review-page.sh hold no logic: they source lib/py.sh and run `sf.py <command>`
for pair in report.sh:report metrics.sh:metrics review-page.sh:review-page; do
  w="$root/scripts/${pair%%:*}"; cmd="${pair##*:}"
  code="$(grep -vE '^[[:space:]]*(#|$)' "$w")"
  [ "$(printf '%s\n' "$code" | wc -l)" -le 5 ] && pass "AC-8 ${pair%%:*} is a few lines" || fail "AC-8 ${pair%%:*} has logic:
$code"
  case "$code" in *'lib/py.sh'*) pass "AC-8 ${pair%%:*} sources lib/py.sh" ;; *) fail "AC-8 ${pair%%:*} does not source lib/py.sh" ;; esac
  case "$code" in *"$cmd"*) pass "AC-8 ${pair%%:*} runs the $cmd command" ;; *) fail "AC-8 ${pair%%:*} never names $cmd" ;; esac
  if printf '%s\n' "$code" | grep -qE '(^|[[:space:];])(if|case|for|while|until)[[:space:]]|git |python|shipfloor_resolve|lib/project\.sh'; then fail "AC-8 ${pair%%:*} has control flow, git or python in it:
$code"; else pass "AC-8 ${pair%%:*} has no control flow, git or python"; fi
done
grep -q 'report.json schema' "$root/scripts/report.sh" && pass "AC-8 report.sh keeps the report.json schema header" || fail "AC-8 report.sh lost its schema header"
[ ! -e "$root/scripts/review_page.py" ] && pass "AC-8 scripts/review_page.py is gone (absorbed in shipfloor_core)" || fail "AC-8 scripts/review_page.py still exists"

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
finish
