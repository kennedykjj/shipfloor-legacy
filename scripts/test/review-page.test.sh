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
ids() { "$FACTORY_PYTHON" -I -c "import re,sys,json;h=open(sys.argv[1],encoding='utf-8').read();d=json.loads(re.search(r'const S=(\[.*?\]);',h,re.S).group(1));print(';'.join(x['id']+'='+str(x['ro']) for x in d))" "$(cygpath -w "$1" 2>/dev/null || echo "$1")"; }
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
finish
