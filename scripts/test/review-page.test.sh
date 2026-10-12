#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
GEN="$FACTORY_DIR/review-page.sh"
d="$(mktemp -d)"
cat > "$d/spec.md" <<'EOS'
# [A1] Update Next.js — spec

**Issue:** #25 · **Branch:** `feat/25-x` · **Date:** 2026-10-08

## Product
_Product Owner_

**Problem:** versions with CVEs.
**Acceptance criteria**
- **AC-1** — Given package.json, when I inspect it, then next ≥ 16.3.3.
- **AC-2** — Given web/, when I list it, then only pnpm-lock.yaml exists.

## UX
_UX/UI Designer_ — n/a

## Test plan
_Tech Lead_

| AC | Layer | Test file |
|---|---|---|
| AC-1 | web | command: pnpm list |

## Security
_Security_ — n/a
- none

## Open questions
- **Target versions:** use the latest patch?
EOS
assert_exit 0 bash "$GEN" "$d/spec.md" 25 feat/25-x "$d/out/25.html"
html="$(cat "$d/out/25.html")"
assert_contains "$html" "<!doctype html>"
assert_contains "$html" "Spec review #25"
assert_contains "$html" "AC-1 — Given package.json"
assert_contains "$html" "Problem: versions with CVEs."
assert_contains "$html" "AC-1 · web · command: pnpm list"
assert_contains "$html" "Target versions: use the latest patch?"
case "$html" in *__DATA__*|*__ISSUE__*) fail "placeholders left" ;; *) pass "no placeholders left" ;; esac
case "$html" in *'"t": "UX"'*|*'"t":"UX"'*|*'"t": "Security"'*) fail "empty section included" ;; *) pass "n/a sections skipped" ;; esac
ids() { python -I -c "import re,sys,json;h=open(sys.argv[1],encoding='utf-8').read();d=json.loads(re.search(r'const S=(\[.*?\]);',h,re.S).group(1));print(';'.join(x['id']+'='+str(x['ro']) for x in d))" "$(cygpath -w "$1" 2>/dev/null || echo "$1")"; }
data="$(ids "$d/out/25.html")"
assert_contains "$data" "open-questions=False;product=True"
assert_contains "$data" "test-plan=True"
# legacy Portuguese spec: "## Dúvidas" is still the editable section
cat > "$d/legacy.md" <<'EOS'
# [A1] Atualizar Next.js — spec

## Produto
_Product Owner_

- **CA-1** — Dado o package.json, então next ≥ 16.3.3.

## UX
_UX/UI Designer_ — não se aplica

## Dúvidas
- **Versões alvo:** usar o patch mais recente?
EOS
assert_exit 0 bash "$GEN" "$d/legacy.md" 26 feat/26-x "$d/out/26.html"
data="$(ids "$d/out/26.html")"
assert_contains "$data" "d-vidas=False;produto=True"
assert_exit 2 bash "$GEN" "$d/missing.md" 25 feat/25-x "$d/out/x.html"

# AC-8: the page served without embed=1 is the standalone page: it carries no dashboard marks, even when marks are stored
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
H="$SHIPFLOOR_HOME"; P="$H/projects/shop"; mkdir -p "$P/logs" "$P/locks" "$P/reviews"
printf 'shop\t/x/shop\t/x/wt\tmain\n' > "$H/registry.tsv"
cp "$FACTORY_DIR/test/fixture/factory.yml" "$P/factory.yml"
cp "$d/out/25.html" "$P/reviews/25.html"
rev="$($PY -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' "$(nat "$P/reviews/25.html")")"
printf '{"rev":"%s","marks":{"product":{"s":"chg","n":"a stored note"}}}' "$rev" > "$P/reviews/25.marks.json"
export FAKE_GH_DIR="$d" FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_NO_JQ=1 CLAUDE_CONFIG_DIR="$(nat "$d")"
$PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$d/dash-out" 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -qs 'http://' "$d/dash-out" && break; sleep 0.1; done
url="$(grep -o 'http://[^ ]*' "$d/dash-out" | tr -d '\r')"; base="${url%%/?t=*}"; tok="${url##*t=}"
# not vacuous: the same stored marks do reach the embedded page
case "$(curl -s "$base/review/shop/25?embed=1&t=$tok")" in *'"a stored note"'*) pass "AC-8 precondition: stored marks reach the embedded page" ;; *) fail "AC-8 precondition: stored marks do not reach the embedded page" ;; esac
plain="$(curl -s "$base/review/shop/25?t=$tok")"
assert_contains "$plain" "Spec review #25"
case "$plain" in *__shipfloorMarks*) fail "AC-8 the page without embed=1 carries __shipfloorMarks" ;; *) pass "AC-8 the page without embed=1 carries no __shipfloorMarks" ;; esac
case "$plain" in *"a stored note"*) fail "AC-8 the page without embed=1 carries stored marks" ;; *) pass "AC-8 the page without embed=1 carries no stored marks" ;; esac
[ "$plain" = "$(cat "$P/reviews/25.html")" ] && pass "AC-8 the page without embed=1 is served as it is on disk" || fail "AC-8 the page without embed=1 differs from the file"
finish
