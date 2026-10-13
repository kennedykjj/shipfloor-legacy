#!/usr/bin/env bash
# Settings > Language: the page's language (language in config.yml) and the language the factory writes in for each
# project (language in factory.yml, or this machine's override in the project's overrides.yml, #129). Every server here runs with SHIPFLOOR_SCHEDULER set to a stub:
# a test never touches the real ShipfloorDispatcher task, nor the real ~/.shipfloor.
source "$(dirname "$0")/lib.sh"
nat() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
PY=python3; $PY -c '' 2>/dev/null || PY=python
C="$(mktemp -d)"; PIDS=""
trap 'kill $PIDS 2>/dev/null' EXIT
BASH_N="$(nat "$(command -v bash)")"

printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$(nat "$C")/stub-ok" > "$C/ok-stub.sh"
OK_CMD="\"$BASH_N\" \"$(nat "$C")/ok-stub.sh\""

# fresh_home: a home with two projects: shop (factory.yml with no language key) and blog (language: pt-BR)
fresh_home() {
  H="$(mktemp -d)"; mkdir -p "$H/logs" "$H/projects/shop/logs" "$H/projects/shop/locks" "$H/projects/blog/logs" "$H/projects/blog/locks"
  printf 'shop\t/x/shop\t/x/wt\tmain\nblog\t/x/blog\t/x/wt2\tmain\n' > "$H/registry.tsv"
  cp "$FACTORY_DIR/test/fixture/factory.yml" "$H/projects/shop/factory.yml"
  { printf 'language: pt-BR\n'; cat "$FACTORY_DIR/test/fixture/factory.yml"; } > "$H/projects/blog/factory.yml"
  rm -f "$C/stub-ok"
}
start_dash() {
  SHIPFLOOR_SCHEDULER="$2" SHIPFLOOR_BASH="$BASH_N" FAKE_GH_NO_JQ=1 FACTORY_GH="$FACTORY_DIR/test/fake-gh" FAKE_GH_DIR="$C" \
    $PY -I "$(nat "$FACTORY_DIR/dashboard.py")" --home "$(nat "$H")" --port 0 --no-open > "$C/out-$1" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do grep -qs 'http://' "$C/out-$1" && break; sleep 0.1; done
  url="$(grep -o 'http://[^ ]*' "$C/out-$1")"; base="${url%%/?t=*}"; tok="${url##*t=}"
}
post() { curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H "X-Shipfloor-Token: $tok" -d "$1" "$base/api/settings/machine"; }
get() { curl -s -H "X-Shipfloor-Token: $tok" "$base$1"; }
jget() { printf '%s' "$1" | $PY -X utf8 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>&1 | tail -n 1; }
page_has() { if curl -s "$base/" | grep -qF -- "$1"; then pass "$2: the page carries '$1'"; else fail "$2: the page does not carry '$1'"; fi; }
cat_has() { if grep -qF -- "$1" "$FACTORY_DIR/lang/dashboard.pt-BR.json"; then pass "$2: the pt-BR catalog carries '$1'"; else fail "$2: the pt-BR catalog does not carry '$1'"; fi; }
# cfgrest: config.yml as JSON without its language key
cfgrest() { $PY -I -c 'import sys,yaml,json; d=yaml.safe_load(open(sys.argv[1])) or {}; d.pop("language",None); print(json.dumps(d,sort_keys=True))' "$(nat "$H/config.yml")" 2>&1; }
cfglang() { $PY -I -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print(d.get("language"))' "$(nat "$H/config.yml")" 2>&1; }

# --- AC-5: no language key in config.yml or in a project's factory.yml: en, the factory default
fresh_home; printf 'pool: 6\n' > "$H/config.yml"; start_dash a "$OK_CMD"
s="$(get /api/settings)"
[ "$(jget "$s" 'd["machine"].get("language")')" = "en" ] && pass "AC-5 config.yml with no language key shows en" || fail "AC-5 machine.language was: $(jget "$s" 'd["machine"].get("language")') (want en)"
got="$(jget "$s" '[(p["language"]["code"], p["language"]["set"]) for p in d["projects"] if p["slug"]=="shop"][0]')"
[ "$got" = "('en', False)" ] && pass "AC-5 a project whose factory.yml has no language key shows en, not set" || fail "AC-5 shop language was: $got (want ('en', False))"

# --- AC-2: one row per registered project: the language the factory writes in and the file that sets it
got="$(jget "$s" '[(p["slug"], p["language"]["code"], p["language"]["set"], p["language"]["file"]) for p in d["projects"] if p["slug"]=="blog"][0]')"
[ "$got" = "('blog', 'pt-BR', True, '.shipfloor/factory.yml')" ] && pass "AC-2 a project with the key shows its language, set, and .shipfloor/factory.yml" || fail "AC-2 blog language was: $got (want ('blog', 'pt-BR', True, '.shipfloor/factory.yml'))"
[ "$(jget "$s" 'len([p for p in d["projects"] if "language" in p])')" = "2" ] && pass "AC-2 every registered project carries a language" || fail "AC-2 projects with a language: $(jget "$s" 'len([p for p in d["projects"] if "language" in p])') (want 2)"
page_has "What the factory writes" "AC-2"
if curl -s "$base/" | grep -qF "Read-only here"; then fail "AC-2 the page still says a project's language is read-only"; else pass "AC-2 a project's language is no longer read-only"; fi
page_has ".shipfloor/factory.yml" "AC-2"

# --- AC-4: the options are the keys of LANGS, each under its own name (#122: the name its catalog gives itself); the page
# lists no language of its own
want="$($PY -I -c 'import sys,json; sys.path.insert(0,sys.argv[1]); import shipfloor_config as c; print(json.dumps({k: json.load(open(sys.argv[1] + "/lang/dashboard." + k + ".json", encoding="utf-8"))["name"] for k in c.LANGS}))' "$(nat "$FACTORY_DIR")" 2>&1)"
got="$(jget "$s" 'json.dumps(d.get("languages"))')"
[ "$got" = "$want" ] && pass "AC-4 /api/settings languages is LANGS, in its own order, each under its own name" || fail "AC-4 languages was: $got (want $want)"
[ "$(jget "$s" 'len(d["languages"])')" = 12 ] && pass "#122 twelve languages on offer" || fail "#122 languages on offer: $(jget "$s" 'len(d["languages"])')"
[ "$(jget "$s" 'd["languages"]["es"] + "|" + d["languages"]["ja"] + "|" + d["languages"]["pt-BR"]')" = "Español|日本語|Português (Brasil)" ] && pass "#122 each language under its own name (Español, 日本語)" || fail "#122 names were: $(jget "$s" 'd["languages"]["es"] + "|" + d["languages"]["ja"]')"
page_has 'lang="${esc(c)}"' "#122 each option declares its language, for its glyphs"
page_has 'id="lang"' "AC-4"
page_has "languages" "AC-4"
# (the date formats of #114 pick their locale from the page's language: only those two expressions may name pt-BR, nothing else on the page)
if curl -s "$base/" | grep -qE 'pt-BR|Brazilian|Português|日本語'; then fail "AC-4 the page names a language code or name of its own"; else pass "AC-4 the page names no language code or name of its own"; fi

# --- AC-3: a language outside LANGS is refused with the reason, config.yml byte for byte as before
fresh_home; printf 'language: en\npool: 6\n' > "$H/config.yml"; cp "$H/config.yml" "$C/config.before"; start_dash b "$OK_CMD"
resp="$(post '{"language":"xx"}')"; code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
[ "$code" = 400 ] && pass "AC-3 saving xx answers 400" || fail "AC-3 saving xx answered $code: $resp"
case "$(jget "$body" 'd.get("error")')" in *"language must be one of en, zh-CN, zh-TW, es, ja, de, fr, pt-BR, ru, ko, it, tr"*) pass "AC-3 the reason says language must be one of the twelve";; *) fail "AC-3 the reason was: $(jget "$body" 'd.get("error")')";; esac
[ "$(jget "$body" 'd["errors"][0]["key"]')" = "err.language" ] && pass "#122 the reason carries its key for the page's language" || fail "#122 the reason's key: $(jget "$body" 'd.get("errors")')"
cmp -s "$H/config.yml" "$C/config.before" && pass "AC-3 config.yml is byte-identical" || fail "AC-3 config.yml changed: $(cat "$H/config.yml")"
page_has "The language was not changed" "AC-3"
cat_has "O idioma não foi alterado" "AC-3"
cat_has "language deve ser um de" "AC-3"

# --- AC-1: pick Portuguese and save: config.yml holds it, /api/lang answers pt-BR with its catalog, agents' text stays raw
fresh_home; printf 'language: en\n' > "$H/config.yml"; start_dash c "$OK_CMD"
resp="$(post '{"language":"pt-BR"}')"; code="${resp##*$'\n'}"
[ "$code" = 200 ] && pass "AC-1 saving pt-BR answers 200" || fail "AC-1 saving pt-BR answered $code: $resp"
[ "$(cfglang)" = "pt-BR" ] && pass "AC-1 config.yml holds language: pt-BR" || fail "AC-1 config.yml language is: $(cfglang)"
l="$(get /api/lang)"
[ "$(jget "$l" 'd.get("language")')" = "pt-BR" ] && pass "AC-1 /api/lang answers pt-BR" || fail "AC-1 /api/lang language was: $(jget "$l" 'd.get("language")') (want pt-BR)"
for kv in "sec.language=Idioma" "lang.factory=O que a fábrica escreve" "lang.dashboard=Idioma deste dashboard" "lang.this=Este dashboard" "set.reload=O idioma aparece depois de recarregar."; do
  k="${kv%%=*}"; [ "$(jget "$l" "d['messages'].get('$k')")" = "${kv#*=}" ] && pass "AC-1 the catalog has $k: ${kv#*=}" || fail "AC-1 $k was: $(jget "$l" "d['messages'].get('$k')")"
done
[ "$(jget "$l" 'd["en"].get("sec.language")')" = "Language" ] && pass "#122 the English catalog comes along, for a key the other lacks" || fail "#122 /api/lang has no English catalog"
pg="$(curl -s "$base/")"
case "$pg" in *'<html lang="pt-BR">'*) pass "#122 the page declares its language (<html lang>)" ;; *) fail "#122 the page does not say <html lang=\"pt-BR\">" ;; esac
case "$pg" in *'id="lang-data">{"language": "pt-BR", "messages": {'*) pass "#122 the page carries its catalog, so the first paint is in pt-BR" ;; *) fail "#122 the page does not carry the pt-BR catalog" ;; esac
cat_has "Salvo como" "AC-1"
[ "$(jget "$(get /api/settings)" 'd["machine"].get("language")')" = "pt-BR" ] && pass "AC-1 /api/settings answers pt-BR" || fail "AC-1 /api/settings machine.language was: $(jget "$(get /api/settings)" 'd["machine"].get("language")')"
case "$pg" in *'<p class="says">${esc(says.text)}</p>'*'<h3 class="ttitle">${c.title ? esc(c.title) : UNTITLED}</h3>'*) pass "AC-1 the agents' text and the titles are shown as written (.says, .ttitle)";; *) fail "AC-1 the agents' text goes through a catalog";; esac
page_has 'id="lang"' "AC-1"
[ -z "$(cat "$C/stub-ok" 2>/dev/null)" ] && pass "AC-1 a language change does not call the scheduler" || fail "AC-1 the scheduler was called: $(cat "$C/stub-ok")"

# --- AC-6: only language changes in config.yml
fresh_home
printf 'language: en\npool: 6\nstages:\n  refine: 3\n  develop: 1\nstacks: 2\nstack_wait: 90\ndispatcher:\n  every_min: 5\n' > "$H/config.yml"
before="$(cfgrest)"; start_dash d "$OK_CMD"
resp="$(post '{"language":"pt-BR"}')"; code="${resp##*$'\n'}"
[ "$code" = 200 ] && pass "AC-6 saving a language answers 200" || fail "AC-6 saving a language answered $code: $resp"
[ "$(cfglang)" = "pt-BR" ] && pass "AC-6 language is now pt-BR" || fail "AC-6 language is: $(cfglang) (want pt-BR)"
[ "$(cfgrest)" = "$before" ] && pass "AC-6 every other key of config.yml is as before" || fail "AC-6 the other keys changed: before $before, after $(cfgrest)"

# --- AC-7: the section says the text a product shows its own users is not a factory setting
page_has "text a product shows its own users is not a factory setting" "AC-7"
cat_has "não é uma configuração da fábrica" "AC-7"

# --- #129 AC-1: each project has a select with LANGS plus "as the repository says", showing the language in effect
ppost() { curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H "X-Shipfloor-Token: $tok" -d "$1" "$base/api/settings/project"; }
plang() { jget "$(get /api/settings)" "[(p['language']['code'], p['language']['repo'], p['language']['from']) for p in d['projects'] if p['slug']=='$1'][0]"; }
fresh_home; printf 'language: en\n' > "$H/config.yml"; start_dash e "$OK_CMD"
[ "$(plang shop)" = "('en', 'en', 'repository')" ] && pass "#129 AC-1 shop: en in effect, en from the repository" || fail "#129 AC-1 shop was: $(plang shop)"
[ "$(plang blog)" = "('pt-BR', 'pt-BR', 'repository')" ] && pass "#129 AC-1 blog: pt-BR in effect, from the repository" || fail "#129 AC-1 blog was: $(plang blog)"
page_has 'data-plang=' "#129 AC-1"
page_has '<option value="">${t("lang.as_repo", { language: said(p.language.repo) })}</option>' "#129 AC-1"
page_has 'aria-label="${ta("lang.project", { project: p.slug })}"' "#129 AC-1"
page_has "a session already running keeps the language it started in" "#129 AC-7"
cat_has "Como o repositório diz: {language}" "#129 AC-1"
cat_has "Idioma em que a fábrica escreve em {project}" "#129 AC-1"
cat_has "uma sessão que já roda continua no idioma em que começou" "#129 AC-7"
cat_has "Fica nesta máquina, por cima do que o repositório diz; o" "#129 AC-7"
if grep -qF "Read-only here" "$FACTORY_DIR/lang/dashboard.pt-BR.json"; then fail "#129 the catalog keeps the read-only sentence"; else pass "#129 the catalog dropped the read-only sentence"; fi

# --- #129 AC-4: an override that differs from factory.yml: the row says what the repository says
resp="$(ppost '{"project":"blog","values":{"language":"en"}}')"
[ "${resp##*$'\n'}" = 200 ] && pass "#129 AC-4 blog set to en on this machine" || fail "#129 AC-4 saving blog's language answered: $resp"
[ "$(plang blog)" = "('en', 'pt-BR', 'machine')" ] && pass "#129 AC-4 blog: en in effect, pt-BR in the repository, from this machine" || fail "#129 AC-4 blog was: $(plang blog)"
page_has 't("lang.set_here", { language: said(p.language.repo) })' "#129 AC-4"
page_has 'aria-describedby="${id}"' "#129 AC-4"
cat_has "definido nesta máquina · o repositório diz {language}" "#129 AC-4"
# the refusal of a project's language reads in the page's sentence, in both languages
page_has 't("lang.project_failed", { project: slug, why:' "#129 AC-6"
cat_has "O idioma de {project} não foi alterado: {why}. Ele continua escrevendo em {language}." "#129 AC-6"

# --- #129 AC-5: the dashboard's language and a project's are independent: changing one never changes the other
[ "$(cfglang)" = "en" ] && pass "#129 AC-5 a project's language left config.yml's alone" || fail "#129 AC-5 config.yml language is: $(cfglang)"
[ "$(jget "$(get /api/lang)" 'd.get("language")')" = "en" ] && pass "#129 AC-5 the dashboard is still in English" || fail "#129 AC-5 /api/lang moved"
resp="$(post '{"language":"pt-BR"}')"
[ "${resp##*$'\n'}" = 200 ] && pass "#129 AC-5 the dashboard set to pt-BR" || fail "#129 AC-5 saving the dashboard's language answered: $resp"
[ "$(plang blog)" = "('en', 'pt-BR', 'machine')" ] && pass "#129 AC-5 blog still writes in en with the dashboard in pt-BR" || fail "#129 AC-5 blog was: $(plang blog)"
[ "$(plang shop)" = "('en', 'en', 'repository')" ] && pass "#129 AC-5 shop still writes in en with the dashboard in pt-BR" || fail "#129 AC-5 shop was: $(plang shop)"
resp="$(ppost '{"project":"shop","values":{"language":"pt-BR"}}')"
[ "$(plang shop)" = "('pt-BR', 'en', 'machine')" ] && [ "$(cfglang)" = "pt-BR" ] && pass "#129 AC-5 shop in pt-BR, the dashboard still pt-BR" || fail "#129 AC-5 shop $(plang shop), dashboard $(cfglang)"
post '{"language":"en"}' >/dev/null
[ "$(plang shop)" = "('pt-BR', 'en', 'machine')" ] && [ "$(cfglang)" = "en" ] && pass "#129 AC-5 the dashboard back in English, shop still pt-BR" || fail "#129 AC-5 shop $(plang shop), dashboard $(cfglang)"
[ -z "$(cat "$C/stub-ok" 2>/dev/null)" ] && pass "#129 a project's language does not call the scheduler" || fail "#129 the scheduler was called: $(cat "$C/stub-ok")"
finish
