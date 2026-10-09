# Fábrica genérica — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** tornar o plugin `mylos` independente do Pickio: config YAML por projeto, N camadas, um dispatcher para vários projetos.

**Architecture:** um helper Python (`mylos_config.py`) lê e valida `.mylos/factory.yml` e responde consultas; os scripts bash existentes (gate, board, dispatch) trocam constantes por essas consultas; um `mylos-dispatch.sh` percorre o registro de projetos; skills e agentes passam a ler `describe`.

**Tech Stack:** bash (Git Bash no Windows), Python 3.11+ com PyYAML, gh CLI, git.

**Spec:** `docs/superpowers/specs/2026-10-09-fabrica-generica-design.md`

## Global Constraints

- Exit dos gates: 0 passa, 1 bloqueia, 2 uso errado/config ausente — nunca passa por engano.
- Python sempre com `-I`, caminhos via `cygpath -w` quando `cygpath` existe; stdout UTF-8 com `\n` (nunca `\r\n`).
- Scripts referenciados por skills/agentes só como `bash ~/.mylos/factory/<script>`.
- `{selector}` nunca é interpolado em string de shell: vira `"$1"` de `bash -c`.
- Nenhum arquivo fora de `scripts/test/` e `docs/` cita `pickio`, `kennedykjj` ou `/c/Users`.
- Comentários e código em inglês; textos para o dono (comentários de issue, colunas) em português, como hoje.
- Commits terminam com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- Caminho de arquivo com espaço ou caractere especial de regex (`.`, `+`, `(`) em `path`/`tests` → o glob→ERE escapa e casa literalmente. Teste em Task 1.
- Duas camadas com `path` sobreposto (`web/` implementadora e `web/e2e/` só de testes) → `layer-of` devolve a implementadora; `scope web` não libera testes de aceite já protegidos pelo `acceptance-intact`. Teste em Task 1 e Task 3.
- Selector com `;`, `$()` ou espaço → chega ao runner como um argumento só, sem executar nada. Teste em Task 3.
- Config inválida em um projeto do registro → só esse projeto é pulado; os outros despacham. Teste em Task 6.
- Gate rodado fora de projeto registrado e sem `FACTORY_CONFIG` → exit 2. Teste em Task 2.

---

### Task 1: helper de config

**Files:** Create `scripts/mylos_config.py`, `scripts/mylos-config.sh`, `scripts/test/fixture/factory.yml`, `scripts/test/config.test.sh`. Modify `scripts/test/lib.sh` (exporta `FACTORY_CONFIG` da fixture).

**Interfaces — Produces:** `mylos-config.sh <cmd>` com `validate | get <a.b> | layers [--implementers] | layer <n> <campo> | regex scope|test-config|forbidden|migrations <arg> | layer-of <arquivo> | describe`. Padrões aplicados por `layer`: `build`="", `agent`="engineer" (implementadoras), `assertions`="", `setup_errors`="", `test_config`=[], `needs_stack`=false, `tests_only`=false, `migrations.comment`="--". `get` com padrões: `project.main`=main, `paths.specs`, `paths.plans`, `limits.<p>.parallel|wip`, `review_criteria`.

- [ ] Fixture: camadas `api` (path `api/`, build `"${FACTORY_MVN:-mvn}" -q test`, test `"${FACTORY_MVN:-mvn}" test -Dtest={selector} -Dsurefire.failIfNoSpecifiedTests=true`, ran `Tests run: [1-9]`, tests `api/src/test/**`, test_config `api/src/test/resources/junit-platform.properties`, migrations `api/src/main/resources/db/migration/V*__*.sql`), `web` (build `"${FACTORY_PNPM:-pnpm}" exec tsc --noEmit && "${FACTORY_PNPM:-pnpm}" test`, test `... exec vitest run {selector}`, ran `Tests +[1-9][0-9]* passed`, tests `web/**/*.test.ts`, `web/**/*.test.tsx`, test_config `web/vitest.config.*`, `web/playwright.config.*`), `e2e` (path `web/`, tests_only, needs_stack, test `... exec playwright test {selector}`, ran `(^|[[:space:]])[1-9][0-9]* passed`, tests `web/e2e/**`); repo `acme/shop`, board `acme/7`, forbidden `docs/engineering/`.
- [ ] Testes (`config.test.sh`): validate ok na fixture; validate falha (exit 1) sem `layers`, com nome `qa`, com regex inválida em `ran`, com `tests_only`+`agent`; `get project.repo`=acme/shop; `get project.main`=main; `get limits.desenvolver.wip`=4; `layers --implementers`=api,web; `layer api agent`=engineer; `regex scope qa` casa `api/src/test/A.kt`, `web/lib/a.test.ts`, `web/e2e/a.spec.ts` e não `web/lib/a.ts`; `regex scope web` casa `web/a.ts`; `regex forbidden` casa `.mylos/factory.yml`, `api/.env`, `docs/engineering/x.md`, não `api/env.kt`; glob com `.`/`+`/espaço casa só literal (`my dir/a+b.ts` vs `my dirXa+b.ts`); `layer-of web/e2e/x.ts`=web; `layer-of README.md` vazio exit 1; `describe` contém `acme/shop` e `api`; saída sem `\r`.
- [ ] Rodar: `bash scripts/test/config.test.sh` → FAIL (script ausente).
- [ ] Implementar `mylos_config.py` (argparse; `--config` ou `FACTORY_CONFIG`; `glob_to_ere` escapando `.^$+(){}[]|\` e `*`,`?`,`**`; validação descrita na spec) e `mylos-config.sh` (resolve via `lib/project.sh` da Task 2 quando existir; nesta task só usa `FACTORY_CONFIG`).
- [ ] Rodar config.test + suíte completa → verde. Commit `feat(config): yaml project config helper`.

### Task 2: resolução de projeto

**Files:** Create `scripts/lib/project.sh`, `scripts/test/project-resolve.test.sh`. Modify `scripts/mylos-config.sh`.

**Interfaces — Produces:** `mylos_resolve [dir]` exporta `FACTORY_CONFIG FACTORY_HOME FACTORY_REPO FACTORY_PROJECT FACTORY_WT_ROOT`; retorna 1 sem projeto. `MYLOS_HOME` padrão `~/.mylos`. Registro: `$MYLOS_HOME/registry.tsv` = `slug⇥repo⇥worktrees`.

- [ ] Testes: com `FACTORY_CONFIG` setado nada muda; sem ele, repo registrado → config = `$MYLOS_HOME/projects/<slug>/control/.mylos/factory.yml`, home = `projects/<slug>`; worktree do repo (`git worktree add`) resolve igual; diretório fora de projeto → `mylos-config.sh get project.repo` exit 2.
- [ ] Implementar comparando `git rev-parse --path-format=absolute --git-common-dir`.
- [ ] Verde; commit `feat(config): resolve the project from the registry`.

### Task 3: gates genéricos

**Files:** Modify `scripts/gate.sh`; tests `gate-*.test.sh` (papéis `backend`→`api`, `frontend`→`web`; `scripts/factory/` sai da lista proibida dos testes, `.mylos/x` entra). Create `scripts/test/gate-layers.test.sh`.

**Interfaces — Consumes:** Task 1/2. **Produces:** `gate.sh [-C wt] scope <papel> <base> | forbidden <base> | acceptance-intact <qa> | migration <base> <spec> | build <base> | red|green <camada> <selector> | stack-lock acquire|release <owner>`.

- [ ] `gate-layers.test.sh` com config própria (camadas `svc-a` path `services/a/`, `svc-b` path `services/b/`, `lib` path `packages/lib/`, test `printf '%s\n' "$1" > "$OUT"; exit ${FAKE_EXIT:-1}`-style fakes): `scope svc-a` passa com `services/a/x.go` e bloqueia `services/b/y.go`; `scope qa` passa em `services/a/x_test.go`; `build` roda só o build de `svc-b` quando só `services/b/` mudou (cwd = `services/b`); `red svc-a 'a; touch PWNED'` não cria `PWNED` e o runner recebe o selector inteiro; `green` sem `ran` na saída → 1; camada desconhecida → 2; migration de `svc-b` imutável na base → 1.
- [ ] Ajustar testes antigos; rodar → FAIL.
- [ ] Implementar no gate: `FORBIDDEN`, `TEST_CONFIG`, allowed por `regex`; `run_selector` com `bash -c "${cmd//\{selector\}/\"\$1\"}" _ "$sel"` em `cd "$ROOT/$path"`; stack lock por `needs_stack`; `ran`/`assertions`/`setup_errors` da camada; migrations por camada; `STACK_LOCK` em `$FACTORY_HOME`.
- [ ] Suíte verde; commit `feat(gate): layers from the project config`.

### Task 4: board genérico

**Files:** Modify `scripts/board.sh`, `scripts/setup-board.sh`, `scripts/test/fake-gh`, `scripts/test/board*.test.sh`.

- [ ] Testes: repo/owner da fixture (`acme/shop`, `acme/7`) aparecem nas chamadas; `move` descobre ids com `gh project view`/`field-list` uma vez e reusa `$FACTORY_HOME/board-ids` (segunda chamada não chama `project view`); query usa `repositoryOwner`.
- [ ] Implementar; fake-gh responde `project view` com `PVT_x` e `field-list` com o campo Status `FLD_x`.
- [ ] Verde; commit `feat(board): board from the project config`.

### Task 5: dispatch.sh por projeto

**Files:** Modify `scripts/dispatch.sh`, `scripts/test/dispatch*.test.sh`.

- [ ] Testes: prompt `/mylos:desenvolver 54`; limites da config (fixture com `limits.desenvolver.parallel: 1` em teste dedicado → só 1 launch); `MYLOS_MAX_PARALLEL=1` com um lock vivo em outro projeto em `$MYLOS_HOME/projects/other/locks` → nada lançado; `--add-dir` = wt, `$FACTORY_HOME/tmp`, `$FACTORY_HOME/reviews` e não `$FACTORY_HOME` puro; ambiente do run tem `FACTORY_CONFIG` e `MYLOS_FACTORY=1`.
- [ ] Implementar; `cleanup_processes` por `<wt>/<n>/` com `[regex]::Escape`.
- [ ] Verde; commit `feat(dispatch): per-project dispatch with a global run limit`.

### Task 6: dispatcher multiprojeto, CLI, installer, reports

**Files:** Create `scripts/mylos-dispatch.sh`, `scripts/mylos`, `scripts/test/mylos-dispatch.test.sh`, `scripts/test/mylos-cli.test.sh`. Modify `scripts/run-dispatcher.sh`, `installer/install-dispatcher.ps1`, `scripts/report.sh`, `scripts/metrics.sh`, `scripts/review_page.py`.

**Interfaces — Produces:** `mylos install|doctor|add <repo> [--worktrees DIR]|remove <slug>|list|pause [slug]|resume [slug]|setup-board <slug>|metrics <slug>`; `mylos-dispatch.sh` (env `MYLOS_HOME`, `MYLOS_DISPATCH` = caminho do dispatch.sh para testes, `FACTORY_CONTROL_REFRESH`).

- [ ] Testes do dispatcher: dois projetos registrados → `dispatch.sh` chamado para os dois com `FACTORY_PROJECT` certo; `~/.mylos/PAUSE` → nenhum; config inválida em um → o outro roda e o log cita o inválido; log recente com `hit your session limit` em qualquer projeto → nenhum.
- [ ] Testes da CLI: `add` em repo com `.mylos/factory.yml` em `origin/main` registra `slug⇥repo⇥wt` e cria `projects/<slug>/control`; `add` repetido não duplica; `add` com config inválida → exit 1 sem registrar; `list` mostra; `pause shop` cria `projects/shop/PAUSE`; `resume shop` remove; `remove shop` tira do registro.
- [ ] Implementar; `review_page.py` usa `<projeto>-spec-<n>-review`; installer cria `MylosDispatcher`.
- [ ] Verde; commit `feat: multi-project dispatcher and mylos CLI`.

### Task 7: skills, agentes, templates e higiene

**Files:** Modify `skills/*/SKILL.md`, `agents/{qa-engineer,product-owner,ux-designer,cybersec}.md`, `templates/*`, `scripts/review-template.html`, `README.md`, `.claude-plugin/plugin.json` (versão 0.2.0). Create `agents/engineer.md`, `examples/factory.yml`, `scripts/test/hygiene.test.sh`. Delete `agents/backend-engineer.md`, `agents/frontend-engineer.md`.

- [ ] `hygiene.test.sh`: grep por `pickio|kennedykjj|/c/Users|\.pickio-factory|scripts/factory` em `skills agents scripts templates installer examples README.md` (exceto `scripts/test/`) → vazio.
- [ ] Rodar → FAIL; reescrever textos conforme spec (seção Skills e agentes); README com instalação (`pip install pyyaml`, `bash <plugin>/scripts/mylos install`, `mylos add`, permissões sugeridas).
- [ ] Suíte completa verde; commit `feat: project-agnostic skills and agents`.
