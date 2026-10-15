#!/usr/bin/env bash
# suite: integration
# review-page.sh (review_page.py, review-template.html). The behavior is in process: py/review_pages.py (the page,
# its refusals, the incremental re-review and --diff, the template's theme and the catalog labels). Here, the wrapper's
# contract through real processes, and the page the dashboard (dashboard.py) serves without embed=1.
source "$(dirname "$0")/lib.sh"
py_suite review_pages
GEN="$FACTORY_DIR/review-page.sh"
d="$(mktemp -d)"
printf '# [A] T — spec\r\n\r\n## Product\r\n_Product Owner_\r\n\r\n- **AC-1** — Given a, when b, then c.\r\n\r\n## Open questions\r\n- **Q:** why?\r\n' > "$d/spec.md"

# usage: exit 2, the usage on stderr only (wrapper and sf.py); a missing spec: exit 2 naming it, no page
bash "$GEN" "$d/spec.md" 25 feat/25-x > "$d/out" 2> "$d/err"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$d/out" ] && grep -q '^usage: review-page.sh <spec.md> <issue> <branch> <out.html>' "$d/err" && pass "review-page.sh with 3 arguments: exit 2, usage on stderr" || fail "usage: exit $rc: $(cat "$d/out" "$d/err")"
out="$("$FACTORY_PYTHON" -I "$FACTORY_DIR/sf.py" review-page 2>&1)"; rc=$?
[ "$rc" = 2 ] && assert_contains "$out" "usage: review-page.sh" || fail "sf.py review-page: exit $rc: $out"
out="$(bash "$GEN" "$d/nope.md" 25 feat/25-x "$d/o/x.html" 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$d/o/x.html" ] && assert_contains "$out" "review-page: spec not found" || fail "missing spec: exit $rc: $out"
# a page: exit 0, the parent folder made, LF only from a CRLF spec
assert_exit 0 bash "$GEN" "$d/spec.md" 25 feat/25-x "$d/o/25.html"
assert_contains "$(cat "$d/o/25.html")" "Spec review #25"
grep -q $'\r' "$d/o/25.html" && fail "the page has CR line endings" || pass "the page uses LF only"
# --diff: the JSON entries on stdout, exit 0; one file: exit 2
out="$(bash "$GEN" --diff "$d/spec.md" "$d/spec.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] && assert_contains "$out" '"status": "untouched"' || fail "--diff: exit $rc: $out"
assert_exit 2 bash "$GEN" --diff "$d/spec.md"

# AC-8: the page served without embed=1 is the standalone page: it carries no dashboard marks, even when marks are stored
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY="$FACTORY_PYTHON"
H="$SHIPFLOOR_HOME"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
cp "$d/o/25.html" "$P/reviews/25.html"
rev="$($PY -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' "$(nat "$P/reviews/25.html")")"
printf '{"rev":"%s","marks":{"product":{"s":"chg","n":"a stored note"}}}' "$rev" > "$P/reviews/25.marks.json"
export FAKE_GH_DIR="$d" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 CLAUDE_CONFIG_DIR="$(nat "$d")"
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$d/dash-out" 2>&1 &
srv=$!; MAINPID=$$; trap '[ "$(exec sh -c "echo \$PPID")" = "$MAINPID" ] && kill $srv 2>/dev/null' EXIT
wait_for "the dashboard's address" grep -qs 'http://' "$d/dash-out"
url="$(grep -o 'http://[^ ]*' "$d/dash-out" | tr -d '\r')"; base="${url%%/?t=*}"; tok="${url##*t=}"
case "$(curl -s "$base/review/shop/25?embed=1&t=$tok")" in *'"a stored note"'*) pass "AC-8 precondition: stored marks reach the embedded page" ;; *) fail "AC-8 precondition: stored marks do not reach the embedded page" ;; esac
plain="$(curl -s "$base/review/shop/25?t=$tok")"
assert_contains "$plain" "Spec review #25"
case "$plain" in *__shipfloorMarks*|*"a stored note"*) fail "AC-8 the page without embed=1 carries the dashboard's marks" ;; *) pass "AC-8 the page without embed=1 carries no __shipfloorMarks and no stored marks" ;; esac
[ "$plain" = "$(cat "$P/reviews/25.html")" ] && pass "AC-8 the page without embed=1 is served as it is on disk" || fail "AC-8 the page without embed=1 differs from the file"
finish
