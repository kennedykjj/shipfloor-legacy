#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
GEN="$FACTORY_DIR/review-page.sh"
d="$(mktemp -d)"
cat > "$d/spec.md" <<'EOS'
# [A1] Atualizar Next.js — spec

**Issue:** #25 · **Branch:** `feat/25-x` · **Data:** 2026-10-08

## Produto
_Product Owner_

**Problema:** versões com CVEs.
**Critérios de aceite**
- **CA-1** — Dado o package.json, quando inspeciono, então next ≥ 16.3.3.
- **CA-2** — Dado o web/, quando listo, então só há pnpm-lock.yaml.

## UX
_UX/UI Designer_ — não se aplica

## Plano de testes
_Tech Lead_

| CA | Camada | Arquivo de teste |
|---|---|---|
| CA-1 | web | comando: pnpm list |

## Dúvidas
- **Versões alvo:** usar o patch mais recente?
EOS
assert_exit 0 bash "$GEN" "$d/spec.md" 25 feat/25-x "$d/out/25.html"
html="$(cat "$d/out/25.html")"
assert_contains "$html" "<!doctype html>"
assert_contains "$html" "Revisão da spec #25"
assert_contains "$html" "CA-1 — Dado o package.json"
assert_contains "$html" "Problema: versões com CVEs."
assert_contains "$html" "CA-1 · web · comando: pnpm list"
assert_contains "$html" "Versões alvo: usar o patch mais recente?"
case "$html" in *__DATA__*|*__ISSUE__*) fail "placeholders left" ;; *) pass "no placeholders left" ;; esac
case "$html" in *'"t": "UX"'*|*'"t":"UX"'*) fail "empty section included" ;; *) pass "não se aplica section skipped" ;; esac
data="$(python -I -c "import re,sys,json;h=open(sys.argv[1],encoding='utf-8').read();d=json.loads(re.search(r'const S=(\[.*?\]);',h,re.S).group(1));print(';'.join(x['id']+'='+str(x['ro']) for x in d))" "$(cygpath -w "$d/out/25.html" 2>/dev/null || echo "$d/out/25.html")")"
assert_contains "$data" "d-vidas=False;produto=True"
assert_contains "$data" "plano-de-testes=True"
assert_exit 2 bash "$GEN" "$d/missing.md" 25 feat/25-x "$d/out/x.html"
finish
