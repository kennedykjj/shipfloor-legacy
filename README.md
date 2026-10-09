# mylos-factory

Plugin do Claude Code que leva issues de um board do GitHub até produção com agentes e gates determinísticos, em qualquer repositório que declare um `.mylos/factory.yml`.

## Como funciona

O board (GitHub Project v2) tem colunas fixas. O dono move os cards entre as colunas 👤, e a fábrica cuida das colunas 🤖:

| Esteira | Pega de | Entrega em | O que faz |
|---|---|---|---|
| `/mylos:refinar` | Ready for Refinement | Spec Review | PO, UX/UI e Cybersec escrevem a spec; o Tech Lead escreve arquitetura e plano de testes |
| `/mylos:desenvolver` | Ready for Dev | Validation | plano, testes de aceite que falham (QA), implementação por camada, atualização com o `main` |
| `/mylos:validar` | Validation | Staged | atualiza com o `main`, gates, review (código, UX, segurança), PR com CI verde |
| `/mylos:deployar` | Ready for Prod | Done | atualiza com o `main` resolvendo conflitos, merge testado sobre o `main` atual, espera CI e deploy; se falhar, abre PR de revert |

Os gates (`scripts/gate.sh`) não dependem do modelo: escopo de arquivos por papel, caminhos proibidos, testes de aceite intactos, migrations imutáveis, build por camada, teste vermelho por asserção (não por erro de compilação) e verde com pelo menos um teste rodado.

Um dispatcher (tarefa agendada a cada 3 min) percorre todos os projetos registrados e lança as esteiras com `claude -p`, respeitando o pool de agentes da máquina, as vagas de cada etapa, os limites do projeto e o WIP.

## Pool de agentes

Cada run de esteira é um agente. `~/.mylos/config.yml` define quantos rodam ao mesmo tempo na máquina, somando todos os projetos, e quantos cabem em cada etapa (números absolutos):

```yaml
pool: 4
stages: {refinar: 2, desenvolver: 2, validar: 2, deployar: 1}
```

`mylos pool` mostra a configuração e os runs em andamento. `mylos pool set 6` e `mylos pool stage validar 3` mudam os valores. O `limits` do `factory.yml` pode limitar mais um projeto.

## Trabalho em paralelo

Cards desenvolvidos ao mesmo tempo não quebram o `main`:
- o gate `migration` recusa versão repetida e migration mais antiga que as do base;
- `desenvolver`, `validar` e `deployar` trazem o `origin/main` antes dos gates;
- o deploy só faz merge de um head que contém o `main` atual e passou no CI.

No deploy, conflitos são resolvidos pela própria esteira. O card volta para Coding só se o conflito envolve migration, se é grande (`deploy.conflict_max_files`/`conflict_max_hunks`) ou se gates ou CI falham depois de resolver.

## Pré-requisitos

`git`, `gh` autenticado, `claude`, Python 3.11+ com PyYAML (`pip install pyyaml`) e Git Bash no Windows.

## Instalação

```bash
bash <plugin>/scripts/mylos install     # copia scripts e templates para ~/.mylos/factory
alias mylos='bash ~/.mylos/factory/mylos'
mylos doctor
```

Para cada repositório:

1. Copie `examples/factory.yml` para `.mylos/factory.yml`, ajuste projeto, board e camadas e faça commit no branch principal.
2. `mylos add <clone local> [--worktrees DIR]`, que lê a config de `origin/main`, valida e registra o projeto.
3. `mylos setup-board <projeto>` cria as colunas e os labels `ui`, `cybersec` e `blocked`.
4. Se quiser, adicione `.mylos/review-criteria.md` e agentes próprios em `.claude/agents/<nome>.md`, referenciados por `agent:` na camada.
5. Permissões para as esteiras headless no `.claude/settings.json` do projeto: `Bash(bash ~/.mylos/factory/gate.sh:*)`, `Bash(bash ~/.mylos/factory/board.sh:*)`, `Bash(bash ~/.mylos/factory/mylos-config.sh:*)`, `Bash(bash ~/.mylos/factory/report.sh:*)`, `Bash(bash ~/.mylos/factory/review-page.sh:*)`, além de `git` e `gh`.

Dispatcher no Windows: `powershell -File <plugin>/installer/install-dispatcher.ps1`, que registra a tarefa `MylosDispatcher`.

## Operação

`mylos list` · `mylos pause [projeto]` · `mylos resume [projeto]` · `mylos remove <projeto>` · `mylos metrics <projeto>`.
Logs em `~/.mylos/logs/dispatcher.log` e `~/.mylos/projects/<projeto>/logs/`. Relatórios no branch órfão `factory-reports` de cada repositório.

## Segurança

- Os scripts rodam da cópia instalada em `~/.mylos/factory`, fora de qualquer worktree.
- A config vem do checkout de controle (`origin/main`), e `.mylos/` é caminho proibido para agentes: um PR da fábrica não muda os gates que o julgam.
- `templates/factory-guard.yml` repete a checagem de caminhos proibidos no GitHub Actions.

## Desenvolvimento

`bash scripts/test/run.sh` roda a suíte. Design em `docs/superpowers/specs/`.
