#!/usr/bin/env bash
# #164: report, metrics and review-page run in Python (sf.py <command>), with the contracts of the Bash scripts.
source "$(dirname "$0")/lib.sh"
SF="$FACTORY_DIR/sf.py"
PY="$FACTORY_PYTHON"
sf() { "$PY" -I "$SF" "$@"; }

for m in report metrics review_page; do
  [ -f "$FACTORY_DIR/shipfloor_core/$m.py" ] && pass "shipfloor_core/$m.py exists" || fail "shipfloor_core/$m.py missing"
done
[ ! -e "$FACTORY_DIR/review_page.py" ] && pass "scripts/review_page.py was absorbed" || fail "scripts/review_page.py still exists"

# Without the commands every case below fails for the same reason: stop here with one line per missing command.
for c in report metrics review-page; do
  case "$(env -u FACTORY_CONFIG SHIPFLOOR_HOME=/nonexistent "$PY" -I "$SF" "$c" 2>&1)" in *"usage: sf.py"*) fail "sf.py has no '$c' command"; missing=1 ;; esac
done
[ -z "${missing:-}" ] || { finish; exit; }

remote="$(mktemp -d)"; git init -q --bare "$remote"
j="$(mktemp)"; m="$(mktemp)"
echo '{"issue":26,"slug":"rl","pipeline":"refine","outcome":"ok","agents":[{"role":"product-owner","tokens":1000,"duration_s":60}],"rounds":{},"gates_failed":[],"manual_edit":null,"started_at":"2026-10-09T10:00:00-03:00","finished_at":"2026-10-09T10:12:00-03:00"}' > "$j"
echo '# Relatorio' > "$m"

# ---- AC-1: help exits 0 before resolving the project; wrong count or failed resolve exits 2
nodir="$(mktemp -d)"
for a in -h --help help; do
  out="$(cd "$nodir" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$nodir/none" "$PY" -I "$SF" report "$a" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && pass "AC-1 sf.py report $a exits 0 without a project" || fail "AC-1 sf.py report $a exit $rc: $out"
  assert_contains "$out" "usage: report.sh <issue> <slug> <pipeline> <report.json> <report.md>"
  out="$(cd "$nodir" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$nodir/none" bash "$FACTORY_DIR/report.sh" "$a" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && pass "AC-1 report.sh $a exits 0 without a project" || fail "AC-1 report.sh $a exit $rc: $out"
done
exit2_says() {  # exit2_says <text> <command...>: exit 2 and the text in the message
  local want="$1" out rc; shift
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = 2 ]; then case "$out" in *"$want"*) pass "exit 2 with '$want'" ;; *) fail "exit 2 but no '$want': $out" ;; esac
  else fail "$* → exit $rc, want 2: $out"; fi
}
exit2_says "usage: report.sh" sf report 1 2 3
exit2_says "usage: report.sh" sf report
exit2_says "usage: report.sh" bash "$FACTORY_DIR/report.sh" 1 2 3
out="$(cd "$nodir" && env -u FACTORY_CONFIG SHIPFLOOR_HOME="$nodir/none" "$PY" -I "$SF" report 1 s refine "$j" "$m" 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "AC-1 sf.py report outside a registered project exits 2" || fail "AC-1 resolve failure exit $rc: $out"

# ---- AC-2: no remote factory-reports -> orphan branch, README first commit, main untouched
r1="$(new_repo)"; git -C "$r1" remote add origin "$remote"; git -C "$r1" push -q origin main
h1="$(mktemp -d)"
assert_exit 0 env FACTORY_HOME="$h1" FACTORY_REPO="$r1" "$PY" -I "$SF" report 26 rl refine "$j" "$m"
first="$(git --git-dir="$remote" rev-list --max-parents=0 factory-reports)"
[ "$(git --git-dir="$remote" show "$first:README.md")" = "# Factory reports" ] && pass "AC-2 root commit holds README.md '# Factory reports'" || fail "AC-2 README in root commit"
[ "$(git --git-dir="$remote" rev-list --count factory-reports)" = 2 ] && pass "AC-2 orphan: README commit plus the report" || fail "AC-2 commits: $(git --git-dir="$remote" log --format=%s factory-reports)"
[ "$(git --git-dir="$remote" merge-base main factory-reports 2>/dev/null | wc -l)" = 0 ] && pass "AC-2 factory-reports shares no history with main" || fail "AC-2 not an orphan"
[ "$(git --git-dir="$remote" rev-list --count main)" = 1 ] && pass "AC-2 main untouched" || fail "AC-2 main changed"
assert_contains "$(git --git-dir="$remote" log --format=%s factory-reports)" "chore(factory): start reports branch"
assert_contains "$(git --git-dir="$remote" log --format=%B -1 factory-reports)" "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
assert_contains "$(git --git-dir="$remote" log --format=%s -1 factory-reports)" "chore(factory): report #26 refine 20"

# ---- AC-2: remote branch exists -> worktree add -B, and pull --rebase runs before the write
other="$(mktemp -d)"; git clone -q "$remote" "$other/c"; git -C "$other/c" config user.email t@t; git -C "$other/c" config user.name t
git -C "$other/c" checkout -q factory-reports
mkdir -p "$other/c/reports/50-else"; echo '{}' > "$other/c/reports/50-else/x.json"
git -C "$other/c" add reports; git -C "$other/c" commit -qm "other report"; git -C "$other/c" push -q origin factory-reports
# a worktree that is already here and behind the remote: only pull --rebase lets the push succeed
assert_exit 0 env FACTORY_HOME="$h1" FACTORY_REPO="$r1" "$PY" -I "$SF" report 27 two develop "$j" "$m"
files="$(git --git-dir="$remote" ls-tree -r --name-only factory-reports)"
assert_contains "$files" "reports/50-else/x.json"
assert_contains "$files" "reports/27-two/develop-"
# a fresh home with a stale local branch of the same name: -B resets it to the remote
r2="$(new_repo)"; git -C "$r2" remote add origin "$remote"; git -C "$r2" branch factory-reports main
h2="$(mktemp -d)"
assert_exit 0 env FACTORY_HOME="$h2" FACTORY_REPO="$r2" "$PY" -I "$SF" report 28 three refine "$j" "$m"
[ "$(git -C "$r2" rev-parse factory-reports)" = "$(git --git-dir="$remote" rev-parse factory-reports)" ] && pass "AC-2 -B reset the local branch to origin's" || fail "AC-2 local/remote differ"
[ "$(git --git-dir="$remote" log --format=%s factory-reports | grep -c 'start reports branch')" = 1 ] && pass "AC-2 one root commit: the remote branch was continued" || fail "AC-2 branch started again"
[ "$(git --git-dir="$remote" rev-list --count main)" = 1 ] && pass "AC-2 main still untouched" || fail "AC-2 main changed"

# ---- AC-3 (stamp, name and subject through the Python entry)
fixed="$(mktemp -d)"; printf '#!/bin/sh\necho 2026-10-14T120000\n' > "$fixed/date"; chmod +x "$fixed/date"
remote_s="$(mktemp -d)"; git init -q --bare "$remote_s"
rs="$(new_repo)"; git -C "$rs" remote add origin "$remote_s"; hs="$(mktemp -d)"
assert_exit 0 env TZ=UTC FACTORY_HOME="$hs" FACTORY_REPO="$rs" "$PY" -I "$SF" report 31 st validate "$j" "$m"
names="$(git --git-dir="$remote_s" ls-tree -r --name-only factory-reports)"
case "$names" in *reports/31-st/validate-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].json*) pass "AC-3 json named <pipeline>-<stamp>" ;; *) fail "AC-3 names: $names" ;; esac
case "$names" in *reports/31-st/validate-*.md*) pass "AC-3 md beside the json" ;; *) fail "AC-3 no md: $names" ;; esac
case "$(git --git-dir="$remote_s" log --format=%s -1 factory-reports)" in "chore(factory): report #31 validate 20"*T??????) pass "AC-3 commit subject carries the stamp" ;; *) fail "AC-3 subject: $(git --git-dir="$remote_s" log --format=%s -1 factory-reports)" ;; esac

# ---- AC-4: the TSV through sf.py metrics: null, rounding, sums, joins
hm="$(mktemp -d)"; rm_="$(new_repo)"; git -C "$rm_" remote add origin "$remote_s"
assert_exit 0 env FACTORY_HOME="$hm" FACTORY_REPO="$rm_" "$PY" -I "$SF" report 26 rl refine "$j" "$m"
mkdir -p "$hm/reports-wt/reports/9-x"
echo '{"issue":9,"slug":"x","pipeline":"develop","outcome":"blocked","agents":[{"tokens":10},{"tokens":null},{"tokens":20}],"rounds":{"a":2,"b":3},"gates_failed":["build","green web x"],"manual_edit":true,"started_at":"2026-10-09T10:00:00-03:00","finished_at":"2026-10-09T10:02:30-03:00"}' > "$hm/reports-wt/reports/9-x/develop-a.json"
echo '{"issue":8,"slug":"y","pipeline":"refine","outcome":"ok","agents":[],"rounds":{},"gates_failed":[],"manual_edit":null}' > "$hm/reports-wt/reports/9-x/refine-b.json"
tsv="$(env FACTORY_HOME="$hm" FACTORY_REPO="$rm_" "$PY" -I "$SF" metrics 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "AC-4 sf.py metrics exits 0" || fail "AC-4 metrics exit $rc: $tsv"
assert_contains "$tsv" $'issue\tpipeline\toutcome\ttokens\tduration_min\trounds\tgates_failed\tmanual_edit'
assert_contains "$tsv" $'26\trefine\tok\t1000\t12\t0\t\t'
assert_contains "$tsv" $'9\tdevelop\tblocked\t30\t2\t5\tbuild,green web x\tTrue'
assert_contains "$tsv" $'8\trefine\tok\t0\t\t0\t\t'
case "$tsv" in *$'\r'*) fail "AC-4 metrics output has CR" ;; *) pass "AC-4 metrics output is LF" ;; esac

# ---- AC-5: pull --rebase fails -> metrics still succeeds and prints
git -C "$hm/reports-wt" remote set-url origin "$hm/does-not-exist"
tsv="$(env FACTORY_HOME="$hm" FACTORY_REPO="$rm_" "$PY" -I "$SF" metrics 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && pass "AC-5 sf.py metrics exits 0 when pull --rebase fails" || fail "AC-5 exit $rc"
assert_contains "$tsv" $'26\trefine\tok\t1000\t12'
tsv="$(env FACTORY_HOME="$hm" FACTORY_REPO="$rm_" bash "$FACTORY_DIR/metrics.sh" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && pass "AC-5 metrics.sh exits 0 when pull --rebase fails" || fail "AC-5 wrapper exit $rc"
assert_contains "$tsv" $'26\trefine\tok\t1000\t12'
exit2_says "not in a registered project" env -u FACTORY_CONFIG SHIPFLOOR_HOME="$nodir/none" "$PY" -I "$SF" metrics

# ---- AC-6 / AC-7: review-page through sf.py
d="$(mktemp -d)"
printf '# [A] T — spec\r\n\r\n**Issue:** #25 · **Branch:** `feat/25-x` · **Date:** 2026-10-08\r\n\r\n## Product\r\n_Product Owner_\r\n\r\n**Problem:** p.\r\n**Acceptance criteria**\r\n- **AC-1** — Given a, when b, then c.\r\n\r\n## Open questions\r\n- **Q:** why?\r\n' > "$d/spec.md"
exit2_says "usage: review-page.sh" sf review-page
exit2_says "usage: review-page.sh" sf review-page "$d/spec.md" 25 feat/25-x
exit2_says "review-page: spec not found" sf review-page "$d/nope.md" 25 feat/25-x "$d/o/x.html"
[ ! -e "$d/o/x.html" ] && pass "AC-6 no page for a missing spec" || fail "AC-6 page written"
exit2_says "spec not found" bash "$FACTORY_DIR/review-page.sh" "$d/nope.md" 25 feat/25-x "$d/o/x.html"
assert_exit 0 sf review-page "$d/spec.md" 25 feat/25-x "$d/o/25.html"
[ "$(wc -c < "$d/o/25.html")" -gt 0 ] && pass "AC-7 page written (parent folder created)" || fail "AC-7 no page"
if grep -q $'\r' "$d/o/25.html"; then fail "AC-7 page has CRLF line endings"; else pass "AC-7 page uses LF only"; fi
html="$(cat "$d/o/25.html")"
assert_contains "$html" "Spec review #25"
assert_contains "$html" "feat/25-x"
for ph in __DATA__ __ISSUE__ __TITLE__ __BRANCH__ __SPEC__ __DATE__ __KEY__; do
  case "$html" in *"$ph"*) fail "AC-7 placeholder $ph left in the page" ;; *) pass "AC-7 $ph filled" ;; esac
done
# the same page as the wrapper makes
assert_exit 0 bash "$FACTORY_DIR/review-page.sh" "$d/spec.md" 25 feat/25-x "$d/o/w.html"
if grep -q $'\r' "$d/o/w.html"; then fail "AC-7 wrapper page has CRLF"; else pass "AC-7 wrapper page uses LF only"; fi

finish
