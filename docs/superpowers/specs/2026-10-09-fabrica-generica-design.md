# Fábrica genérica — design

**Data:** 2026-10-09 · **Status:** aprovado em conversa (seções 1–7)

## Objetivo

O mylos-factory foi importado do Shop com tudo fixo: board `acme/2`, repo `acme/shop`, caminhos `~/git/shop*`, `~/.shop-factory`, camadas `api/` (Maven) e `web/` (pnpm) e domínio do Shop dentro dos agentes. O objetivo é que o plugin `mylos` sirva a **qualquer repositório** que declare uma config, sem mudar o fluxo do board nem enfraquecer os gates.

**Sucesso:** um repo-fixture com camadas arbitrárias (nomes, caminhos e comandos diferentes de api/web) passa por todos os gates e pelo dispatcher nos testes; nenhum arquivo do plugin cita Shop, `acme` ou caminhos da máquina.

**Fora de escopo:** migrar o Shop (próximo passo); publicar no marketplace; rodar em Linux/macOS além do que já funciona (o installer continua Windows).

## Decisões (da conversa)

| Tema | Decisão |
|---|---|
| Formato de camadas | Livre: lista de N camadas, cada uma com caminho, comandos e agente |
| Agentes | Híbrido: `engineer` genérico por padrão; camada pode declarar `agent: <nome>` (agente do projeto em `.claude/agents/`) |
| Vários projetos | Um dispatcher por máquina percorre um registro; locks/logs/PAUSE por projeto; limite global de runs |
| Config | YAML em `.mylos/factory.yml` no repo alvo, lida por helper Python com PyYAML (pré-requisito, checado por `mylos doctor`) |
| Gates | Continuam em bash; constantes viram consultas ao helper `mylos_config.py` |
| Shop | Fora desta entrega |

## Arquitetura

```
plugin mylos (este repo)              máquina                                   repo alvo
├─ skills/{refinar,desenvolver,       ~/.mylos/                                 ├─ .mylos/factory.yml
│   deployar}/SKILL.md                ├─ factory/   ← cópia instalada de        ├─ .mylos/review-criteria.md (opcional)
├─ agents/{engineer,qa-engineer,      │   scripts/ + templates/ (mylos install) ├─ .claude/agents/<override>.md (opcional)
│   product-owner,ux-designer,        ├─ registry.tsv  slug⇥repo⇥worktrees      └─ PRODUCT.md, CLAUDE.md, … (contexto)
│   cybersec}.md                      ├─ PAUSE         (global)
├─ scripts/ (gates, board, dispatch,  └─ projects/<slug>/
│   mylos CLI, mylos_config.py)           ├─ control/  checkout de origin/main
└─ templates/                             ├─ locks/ logs/ tmp/ reviews/ reports-wt/
                                          ├─ wt/<n>/   worktrees (padrão)
                                          └─ PAUSE, board.tsv, board-ids
```

- **Scripts instalados em caminho fixo.** `mylos install` copia `scripts/` e `templates/` do plugin para `~/.mylos/factory/`. Skills e agentes chamam `bash ~/.mylos/factory/<script>` — caminho literal, que regras de permissão conseguem casar e que fica fora de qualquer worktree e de qualquer `--add-dir` dado aos pipelines (um agente não edita o gate que o julga). `mylos doctor` avisa quando a cópia instalada difere do plugin.
- **Config vem do `origin/main`, fora do alcance dos runs.** A cada ciclo o dispatcher leva `~/.mylos/projects/<slug>/control` a `origin/main` e copia o `.mylos/factory.yml` commitado (`git show HEAD:`) para `~/.mylos/projects/<slug>/factory.yml`. Os gates leem só essa cópia, que fica fora do cwd dos pipelines e de todo `--add-dir`: nem um PR nem uma edição no checkout de controle durante um run alteram os comandos que os gates executam. `.mylos/` é caminho proibido para agentes.
- **Resolução do projeto** (`scripts/lib/project.sh`): se `FACTORY_CONFIG` está no ambiente (pipelines headless e testes), usa-o junto com `FACTORY_HOME`, `FACTORY_REPO`, `FACTORY_PROJECT`, `FACTORY_WT_ROOT`. Senão procura em `~/.mylos/registry.tsv` o projeto cujo `git --git-common-dir` é o mesmo do diretório atual (o checkout do usuário, o controle ou um worktree) e deriva o resto. Sem projeto → exit 2.

## Config `.mylos/factory.yml`

```yaml
project:
  name: shop                    # slug: [a-z0-9-]+; nome do diretório em ~/.mylos/projects
  repo: acme/shop               # owner/repo no GitHub
  main: main                    # opcional, padrão main
board: {owner: acme, number: 3} # GitHub Project v2 (usuário ou organização)
context: [PRODUCT.md, CLAUDE.md]          # lidos por PO/UX/Cybersec/Tech Lead; opcional
review_criteria: .mylos/review-criteria.md # opcional; padrão = template do plugin
forbidden: [docs/engineering/]            # globs extras proibidos a agentes; opcional
paths: {specs: docs/superpowers/specs/, plans: docs/superpowers/plans/}  # opcional (estes são os padrões)
limits:                                    # opcional (estes são os padrões)
  refinar: {parallel: 2, wip: 2}
  desenvolver: {parallel: 2, wip: 4}
  deployar: {parallel: 1}
layers:
  - name: api                   # [a-z0-9-]+; não pode ser po|ux|techlead|qa
    path: services/api/         # área que o implementador da camada pode editar
    stack: Go 1.23              # descrição livre, vai para o agente genérico
    agent: go-engineer          # opcional; padrão engineer
    build: go test ./...        # roda com cwd = path quando a camada mudou; opcional
    test: go test ./... -run {selector}   # usado por red/green; {selector} vira "$1" (nunca interpolado)
    ran: '^ok '                 # regex na saída que prova que algum teste rodou
    tests: ['services/api/**/*_test.go']  # onde o QA escreve testes desta camada
    test_config: []             # configs de runner proibidas ao implementador
    assertions: '--- FAIL'      # opcional; soma-se ao padrão do gate red
    setup_errors: 'build failed'# opcional; soma-se ao padrão do gate red
    migrations: {glob: 'services/api/migrations/*.sql', comment: '--'}  # opcional
  - name: e2e
    path: web/
    tests_only: true            # sem implementador: só QA escreve aqui
    needs_stack: true           # red/green pegam o stack lock
    test: npx playwright test {selector}
    ran: '[1-9][0-9]* passed'
    tests: ['web/e2e/**']
stack: {url: http://localhost:3000}       # opcional; existe = há stack local compartilhada (verify-ui, e2e)
deploy: {ci_workflow: CI, environment: production, timeout_min: 30}  # opcional; cada chave opcional
```

Globs: `**` casa qualquer coisa (inclusive `/`), `*` e `?` não atravessam `/`, entrada terminada em `/` é prefixo. O helper converte para ERE.

Validação (`mylos_config.py validate`, rodada pelo dispatcher antes de cada ciclo do projeto e por `mylos add`): chaves obrigatórias (`project.name`, `project.repo`, `board.owner`, `board.number`, ≥1 camada com `name`, `path`, `test`, `ran`, `tests`), nomes únicos e válidos, `tests_only` sem `agent`/`build`, regex compiláveis. Config inválida → o projeto é pulado no ciclo com log; os outros seguem.

## Helper `scripts/mylos_config.py`

CLI de leitura, sem efeitos colaterais; stdout sempre em UTF-8 com `\n`. Wrapper bash `scripts/mylos-config.sh` resolve o projeto e chama o Python (`python3` ou `python`, `-I`, caminhos via `cygpath -w` quando existe).

| Comando | Saída |
|---|---|
| `validate` | nada; exit 1 + erros em stderr |
| `get <a.b.c>` | escalar; lista = um item por linha; ausente = vazio, exit 1 |
| `layers [--implementers]` | nomes, um por linha |
| `layer <nome> <campo>` | valor do campo (com padrões aplicados) |
| `regex scope <papel>` | ERE dos caminhos permitidos ao papel (`qa` = união de `tests`; camada = `path`; `po`/`ux` = specs; `techlead` = specs+plans) |
| `regex test-config` | ERE da união de `test_config` |
| `regex forbidden` | ERE dos caminhos proibidos (embutidos + `forbidden`) |
| `regex migrations <camada>` | ERE do glob de migrations |
| `layer-of <arquivo>` | camada implementadora dona do arquivo (primeira cujo `path` casa) |
| `describe` | resumo legível do projeto para o Tech Lead: caminhos resolvidos (home, worktrees, tmp), board, contexto, camadas com comandos e agente, stack, deploy |

Embutidos proibidos: `.github/`, `.githooks/`, `.claude/`, `.mylos/`, `CLAUDE.md`, `.gitattributes`, `.mcp.json`, qualquer `.env*`.

## Gates (`scripts/gate.sh`)

Mesma interface de saída (0 passa, 1 bloqueia, 2 uso errado). Mudanças:

- `scope <papel> <base>`: papel ∈ `po|ux|techlead|qa|<camada implementadora>`. Implementador também não toca `test_config` de nenhuma camada. Sempre termina com `forbidden`.
- `build <base>`: para cada camada com `build` e arquivos alterados sob `path`, roda `build` com cwd = `path`.
- `red|green <camada> <selector>`: roda `test` da camada (`bash -c "<test com {selector}→\"\$1\">" _ "<selector>"`, cwd = `path`); `needs_stack` pega o stack lock; `green` exige `ran`; `red` usa os padrões embutidos + `assertions`/`setup_errors` da camada.
- `migration <base> <spec>`: percorre todas as camadas com `migrations`; arquivo já existente na base é imutável; destrutivo (`drop|rename|truncate|delete` fora de comentários com o prefixo `comment`) exige `## Rollback` preenchido.
- `stack-lock`: lock em `$FACTORY_HOME/locks/stack.lock` (por projeto).
- `acceptance-intact`: sem mudança.

## Board (`scripts/board.sh`, `scripts/setup-board.sh`)

Colunas e regras de dono continuam fixas (são o fluxo da fábrica). Owner, número e repo vêm da config. A query usa `repositoryOwner(login:) { ... on ProjectV2Owner { projectV2(number:) } }`, que serve a usuário e organização. `PROJECT_ID` e o id do campo Status são descobertos com `gh project view`/`field-list` e guardados em `$FACTORY_HOME/board-ids`. `setup-board.sh` cria/atualiza as colunas e labels (`ui`, `cybersec`, `blocked`) preservando o status dos cards por nome.

## Dispatcher

- `scripts/mylos-dispatch.sh` (novo, chamado a cada 3 min por `run-dispatcher.sh`): sai se `~/.mylos/PAUSE`; sai se algum log recente de qualquer projeto mostra limite de uso; para cada linha do registro: atualiza `control` para `origin/main` (só quando mudou, com retry), valida a config, exporta `FACTORY_*` do projeto e roda `dispatch.sh`.
- `scripts/dispatch.sh`: igual ao atual, mas lê limites da config, respeita `MYLOS_MAX_PARALLEL` (padrão 3) contando locks vivos de **todos** os projetos em `$MYLOS_HOME/projects/*/locks`, lança `/mylos:<pipeline> <n>` com cwd = `control`, `--add-dir` apenas para `wt`, `tmp` e `reviews`, exporta `FACTORY_*` e `MYLOS_FACTORY=1`, e libera ao fim um stack lock deixado pelo run. A limpeza de processos mata processos cuja linha de comando contém `<worktrees>/<n>/`.
- `installer/install-dispatcher.ps1`: tarefa `MylosDispatcher` rodando `~/.mylos/factory/run-dispatcher.sh`.

## CLI `scripts/mylos`

`install` (copia scripts/templates para `~/.mylos/factory`, cria diretórios), `doctor` (git, gh autenticado, claude, python, PyYAML, cópia instalada em dia, configs válidas), `add <repo-local> [--worktrees DIR]` (lê `.mylos/factory.yml` de `origin/main`, valida, registra), `remove <slug>`, `list`, `pause [slug]`, `resume [slug]`, `setup-board <slug>`, `metrics <slug>`.

## Skills e agentes

- Skills (`refinar`, `desenvolver`, `deployar`) começam rodando `bash ~/.mylos/factory/mylos-config.sh describe` e usam dali repo, worktrees, tmp, specs, plans, camadas e deploy. Nenhuma cita Shop, api/web, mvn ou pnpm; rotas por camada ("arquivo → dono") usam `layer-of`. `deployar` pula a espera de CI/deploy quando a config não tem `ci_workflow`/`environment`.
- Agentes genéricos: `engineer` (recebe `layer`, `path`, `stack`, `build`, `test` na chamada e segue `CLAUDE.md` + código vizinho), `qa-engineer` (testes só nos globs `tests` da camada do plano), `product-owner`, `ux-designer` e `cybersec` (domínio vem dos arquivos de `context`). `backend-engineer` e `frontend-engineer` saem do plugin (viram override do Shop na migração).
- Templates: `spec-template.md` sem termos do Shop; `review-criteria.md` genérico (sem Kotlin/R2/Asaas); `factory-guard.yml` com `.mylos/` no lugar de `scripts/factory/`; chave do review page = `<projeto>-spec-<n>-review`.

## Erros

- Projeto não resolvido, config ausente ou inválida → exit 2 em gates/board (nunca passa).
- Camada desconhecida em `red`/`green`/`scope` → exit 2.
- Falha de leitura do board → ciclo do projeto aborta (fail closed), outros projetos seguem.

## Testes

- `lib.sh` exporta `FACTORY_CONFIG` de `scripts/test/fixture/factory.yml` (camadas `api`, `web`, `e2e` com comandos `${FACTORY_MVN:-mvn}`/`${FACTORY_PNPM:-pnpm}`), preservando as suítes atuais com papéis renomeados (`backend`→`api`, `frontend`→`web`).
- Novos: `config.test.sh` (validate, get, regex, layer-of, describe, glob→ERE), `gate-layers.test.sh` (fixture com 3 camadas fora do padrão api/web: scope, build, red/green, migration), `project-resolve.test.sh` (registro → config do controle), `mylos-dispatch.test.sh` (vários projetos, PAUSE global e por projeto, limite global, config inválida pula só aquele projeto), `mylos-cli.test.sh` (add/list/remove/pause).
- Teste de higiene: `grep` em `skills/ agents/ scripts/ templates/ installer/` (fora de `scripts/test/`) não encontra `shop`, `acme` nem `/c/Users`.
