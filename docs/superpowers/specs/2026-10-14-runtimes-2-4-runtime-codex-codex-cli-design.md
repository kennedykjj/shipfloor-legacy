# Runtimes 2/4: runtime codex (Codex CLI) — spec

**Issue:** #150 · **Branch:** `feat/150-runtimes-2-4-runtime-codex-codex-cli` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** a fábrica só roda agentes pelo Claude Code; quem usa o Codex CLI (ou bate no limite do Claude) não consegue levar um card de refine a validate com outro runtime mantendo gates, custo, pausa no limite e mensagens do dono.
**Audience:** o dono da fábrica e os outros desenvolvedores que instalam o plugin.
**Acceptance criteria**
- **AC-1** — Dado `runtime: codex` e o card de exemplo, quando o pipeline roda com um `codex` falso, então o card passa por refine → develop → validate (e uma execução real com o Codex fica registrada no PR).
- **AC-2** — Dado um agente Codex em execução, quando ele tenta escrever nos scripts instalados da fábrica ou em `.shipfloor/`, `.github/`, `.codex/` ou `AGENTS.md` do repositório, então a sandbox ou os gates `forbidden`/`scope` barram a escrita.
- **AC-3** — Dado `runtime.models` configurado e um gate que falhou, quando o develop roda de novo, então usa o modelo do Codex configurado e sobe um degrau de `runtime.ladder`; sem escada, não sobe; `models.stages` só vale para `claude-code`.
- **AC-4** — Dada uma execução Codex cuja saída contém `You’ve hit your usage limit` (ou uma das variantes de limite), quando ela termina, então o outcome é `usage_limit` e novas execuções esperam 30 minutos.
- **AC-5** — Dada uma mensagem enviada pelo dashboard durante uma execução Codex, quando o agente segue trabalhando, então ela chega ao agente (pelo hook ou no começo do passo seguinte) e aparece como `owner` no Live.
- **AC-6** — Dada uma execução Codex concluída, quando o dono abre o dashboard, então vê as Sessions com tokens por modelo e subagentes, e o Live com falas e comandos.
- **AC-7** — Dada uma execução Codex, quando o dashboard mostra o custo, então mostra US$ se o modelo tem preço e `$ ?` com os tokens se não tem, nunca zero.
- **AC-8** — Dado `shipfloor doctor`, quando roda, então mostra `ok`/`FAIL` para o `codex`, o login e o `CODEX_HOME` gerado; e com `runtime: claude-code` nada muda (a suíte atual inteira passa).
**Out of scope:** o contrato de adaptador de runtime (#149) e os runtimes seguintes (#151, #152); usar o `~/.codex` pessoal do dono; catálogo fixo de modelos da OpenAI (o nome é livre); mudar o texto que o Claude Code recebe hoje.
**Product fit:** serve o princípio 2 (os gates continuam sendo a barreira, qualquer que seja o agente) e o 3 (custo do Codex medido dos rollouts, e `$ ?` quando não há preço, nunca zero). Contradiz o Positioning ao pé da letra ("cost is measured from the Claude Code transcripts"): o Positioning precisa passar a dizer "dos transcripts de cada runtime".
**Touches UI:** yes (custo/`$ ?`, Sessions e Live para Codex, campo de modelo em texto livre no Settings)

## UX
_UX/UI Designer_

- **Custo sem preço:** onde houver custo de uma execução Codex (tile, Feed, peek, stats do drawer, Sessions e a linha de total, History), um modelo sem preço em `prices.yml` mostra `money(null)`: o `$ ?` existente (`.unpriced`, tooltip `cost.unpriced`), nunca `$0.00`. Os tokens já aparecem nas colunas input/output/cache da Sessions, então nenhum texto novo de tokens. Se o card tem parte com preço e parte sem, o total vira `$ ?` (Estimate Rule).
- **Sessions e Live:** uma execução Codex usa as mesmas linhas da Claude: linha de sessão com estágio e modelo, sub-linhas tracejadas para subagentes, tag `stepped up` quando subiu na `runtime.ladder`; no Live, falas, comandos em mono e mensagens do dono como `owner`. Sem rótulo nem cor por runtime: o nome do modelo já identifica.
- **Nome do modelo:** `cap()` só vale para os aliases do Claude (`m.choices`: opus, sonnet, haiku); qualquer outro nome aparece literal, sem mudar caixa (`gpt-6-sol`, não `Gpt-6-sol`), no Settings, na Sessions e na dica de modelo da decisão.
- **Settings, Agents and models:** num estágio cujo runtime não tem lista de modelos, o `<select>` vira o campo de texto já usado em Resources (`.cin` + `input type="text"`, `autocomplete="off"`, `spellcheck="false"`, `aria-label` de `models.aria`/`models.aria.<weight>`), com placeholder `models.default` preenchido por `models.def.codex`. Vazio = padrão do runtime; o valor é aparado (trim); mudança marca `.dirty` e entra na barra de salvar existente. Nome sem preço mostra o `models.no_price` existente, com o nome literal. Estágios em `claude-code` seguem com o select atual.
- **Estados do campo:** vazio mostra o placeholder; salvando, a barra de salvar já cobre; erro de gravação usa a nota `.inv` existente; nenhum catálogo de modelos da OpenAI é sugerido (fora de escopo).
- **Tela pequena:** abaixo de 1180px a linha empilha como as outras (`.srow`), o campo ocupa a largura da coluna, alvo ≥ 24px de altura; nomes longos não quebram a linha, rolam dentro do campo.
- **Limite de uso:** o texto do dispatcher e da notificação nomeia o runtime que bateu no limite (`Claude` ou `Codex`); com `claude-code` a frase fica idêntica à de hoje. O alerta do dashboard (`alert.usage`, `why.usage`) já é neutro e não muda.
- **Copy nova (dashboard, chave `models.def.codex`, ao lado de `models.def.claude`):** en `Codex's` · pt-BR `o do Codex` · es `el de Codex` · fr `celui de Codex` · de `das von Codex` · it `quello di Codex` · ja `Codex のもの` · ko `Codex 기본값` · zh-CN `Codex 的` · zh-TW `Codex 的` · ru `как в Codex` · tr `Codex varsayılanı`.
- **Copy alterada (dispatcher e notify, que só têm en e pt-BR):** `{runtime} usage limit hit recently; waiting` → pt-BR `limite de uso do {runtime} atingido há pouco; aguardando`; `The {runtime} usage limit was hit. New runs wait for it to reset.` → pt-BR `O limite de uso do {runtime} foi atingido. Novas execuções esperam ele voltar.` (`pt-BR.sed` e `notify.pt-BR.json`).
- **Tokens e componentes:** nenhum componente, cor ou token novo; custo em `text` com `est`, `$ ?` em `.unpriced`, campo em `.cin`, avisos em `small.warn`.

## Architecture
_Tech Lead_

Pré-requisito: o contrato de #149 na `main` (`scripts/runtimes/`, `RT_*`, `outcome=` na linha `== end`, `runtimes.sessions`, `SHIPFLOOR_TRAILER`). O dispatcher hoje é Python (`scripts/shipfloor_core/dispatch.py`, `cycle.py`, `deploy.py`, `report.py`); as referências da issue a `dispatch.sh`/`deploy.sh:30`/`report.sh:39` valem para os equivalentes Python. Camada única: `factory`.

**Contratos tocados**
- Config (`scripts/shipfloor_config.py`): `runtime.models` (`stages`: modelo ou mapa por peso; `refine`: um modelo só; `agents`) e `runtime.ladder` (lista). Chave desconhecida em `runtime` = config inválido. `stage-models` passa a devolver, para uma etapa não-`claude-code`, os modelos de `runtime.models`; `next_model` usa a `ladder` do runtime da etapa (vazia = sem subida). Aviso no doctor quando `models.stages.<etapa>` e o runtime da etapa não é `claude-code`.
- Registro: `scripts/runtimes/__init__.py` `NAMES += ("codex",)`.
- Adaptador shell novo `scripts/runtimes/codex.sh`: `rt_run` (`codex exec -s workspace-write -C <control> [-m] --add-dir <cada RT_WRITE> --skip-git-repo-check --json -o <RT_LOG>.last -`, `CODEX_HOME` da fábrica, prompt = `<CODEX_HOME>/sf/<etapa>.md` + `Card: #<n>`), `rt_outcome` (regex de limite sobre o trecho do log **e** o `.last`: `You(.|\\u2019)ve hit your usage limit|out of credits|hit your spend cap|Quota exceeded|upgrade to Plus|exceeded retry limit, last status: 429`; `rc==0` → `ok`; senão `fail`), `rt_doctor` (`codex` no PATH e versão mínima; `codex login status` com o `CODEX_HOME` ou `CODEX_API_KEY`; `config.toml` e `agents/` gerados), `RT_TRAILER="Co-Authored-By: Codex <noreply@openai.com>"`.
- Módulo Python novo `scripts/runtimes/codex.py`: `NAME`, `MODELS=()`, `LADDER=()`, `data_dir()` (`SHIPFLOOR_CODEX_HOME` ou `~/.shipfloor/runtimes/codex`), `session_files` (rollouts cujo `session_meta.cwd` é o `control` do projeto; subagentes por `parent_thread_id`; lê `.jsonl.zst` se houver `zstd`/`zstandard`, senão ignora com uma linha de aviso), `stamp`, `parse` (etapa pelo marcador `<!-- sf:stage=<etapa> -->`, card por `Card: #<n>`, tokens de `token_usage_record` ou `token_count`, modelo de `turn_context`; hora local → UTC; `input = input_tokens − cached_input_tokens`, `cache_read = cached_input_tokens`, `output = output_tokens`), `events` (`response_item` → `says`/ferramenta; mensagem do dono → `owner`).
- Gerador novo `scripts/runtimes/codex_gen.py`, chamado por `shipfloor install` (`scripts/shipfloor_core/cli.py` `cmd_install`): grava em `<CODEX_HOME>` o `config.toml` (chaves da issue §1), `agents/<nome>.toml` (`name`, `description`, `developer_instructions` = corpo do `.md`, `model` de `runtime.models.agents`; o `model:` do frontmatter não é copiado), `hooks.json` (se o hook servir) e `sf/<etapa>.md` com o frontmatter removido, o marcador de etapa e os marcadores resolvidos. Idempotente; não toca em `auth.json`.
- Marcadores de runtime nas fontes (`skills/{refine,develop,validate,deploy}/SKILL.md`, `agents/*.md`): blocos `<!-- rt:codex -->…<!-- /rt -->` e equivalentes para chamar subagente, ferramentas de arquivo, regras do headless, mensagem do dono, pasta pessoal, trailer/rodapé e `verify-ui`. O plugin do Claude Code lê o arquivo como está, então o texto visível ao Claude não muda: os blocos do Codex ficam em comentário HTML e o gerador os expande, removendo os do Claude.
- Trailer: `defaults.TRAILER` vira o padrão de `SHIPFLOOR_TRAILER` (já previsto em #149); `deploy.py` e `report.py` leem o do runtime da etapa.
- Mensagens do dono (`scripts/inbox_hook.py`): modo Codex (`--codex`, entrada e saída do hook do Codex) se o `PostToolUse` do Codex devolver contexto; senão, o prompt gerado manda ler `<SHIPFLOOR_RUN_LOCK>/inbox` a partir de `inbox.lead` no começo de cada passo e gravar o contador, mesmo protocolo.
- Custo e dashboard: `templates/prices.yml` ganha os modelos da OpenAI conhecidos; `scripts/dashboard.py` (`priced` em `models()`, ~l.955) e `scripts/dashboard.html` (`priced` ~l.2247, `cap()` só para os aliases do Claude, campo de texto livre quando `MODELS=()`) passam a usar o nome completo do modelo; `$ ?` conforme `## UX`.
- Limite de uso nomeado: `scripts/shipfloor_core/cycle.py:254`, `scripts/shipfloor_notify.py:23`, `scripts/lang/pt-BR.sed`, `scripts/lang/notify.pt-BR.json` com `{runtime}`; `models.def.codex` nos 12 `scripts/lang/dashboard.*.json`.
- Docs: `docs/configuration.md` (seção Runtime: Codex, `runtime.models`/`ladder`), `docs/install.md` (instalar o Codex, `CODEX_HOME=… codex login`), `docs/operation.md` (mensagem no Codex chega no passo seguinte), `docs/how-it-works.md:18,22` (citar o runtime), `docs/contracts.md` (prompt do Codex), `PRODUCT.md` (Positioning: custo "dos transcripts de cada runtime").

**Módulos:** `scripts/runtimes/` (novos `codex.sh`, `codex.py`, `codex_gen.py`), `scripts/shipfloor_config.py`, `scripts/shipfloor_core/{dispatch,cycle,cli,deploy,report}.py`, `scripts/inbox_hook.py`, `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/shipfloor_notify.py`, `scripts/lang/*`, `templates/prices.yml`, `skills/*/SKILL.md`, `agents/*.md`, docs acima.

**Sandbox e escrita (AC-2):** raízes graváveis = `RT_WRITE` (worktrees, `tmp`, `reviews`); `~/.shipfloor/factory`, o `reports-wt` e o `CODEX_HOME` ficam fora. `.shipfloor/`, `.github/`, `.codex/`, `AGENTS.md` dentro do worktree são graváveis pela sandbox e barrados pelos gates `forbidden`/`scope` (cobertos por #149).

**Riscos a confirmar no começo da implementação (⚠):** (1) o `workspace-write` do Codex deixa `.git` só leitura dentro das raízes graváveis; os worktrees escrevem no `.git` do `control`: se o commit falhar, o card vai para `blocked` com o achado, sem contornar a sandbox; (2) se o `PostToolUse` injeta contexto; (3) se `reasoning_output_tokens` já está em `output_tokens`; (4) a confiança do hook (`trusted_hash` vs `--dangerously-bypass-hook-trust`).

**Migração:** nenhuma de dados. Config novo é aditivo; sem `runtime`, nada muda.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/dispatch_cycle.py` |
| AC-2 | factory | `scripts/test/py/dispatch_launch.py` |
| AC-3 | factory | `scripts/test/py/dispatch_launch.py` |
| AC-4 | factory | `scripts/test/py/dispatch_cycle.py` |
| AC-5 | factory | `scripts/test/py/dashboard_cards.py` |
| AC-6 | factory | `scripts/test/py/dispatch_cost.py` |
| AC-7 | factory | `scripts/test/py/dispatch_cost.py` |
| AC-8 | factory | `scripts/test/py/cli_doctor.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Testes com um `codex` falso (script em `scripts/test/` que grava argv/stdin e escreve um rollout), nas suítes existentes do dispatch, do custo, do inbox e do doctor: nenhuma suíte nova além da `runtime.test.sh` que #149 cria.
- Dúvida 1 da issue (hook vs inbox) fica para o começo da implementação, como a issue decidiu; os dois caminhos já estão desenhados e o AC-5 aceita qualquer um.
- Dúvida 2 da issue: o log guarda o JSONL do `--json` (depuração) e o `-o` grava o texto final ao lado; `rt_outcome` lê os dois, porque o JSON pode escapar o `’` como `’`.
- Marcadores de runtime em comentário HTML nas skills e agentes: mantém fonte única sem mudar o que o Claude Code lê.
- `.jsonl.zst` só é lido se houver descompressor; sem ele, os rollouts de mais de 7 dias ficam de fora com aviso, porque o projeto é stdlib + PyYAML.
- `PRODUCT.md` (Positioning) é atualizado no mesmo PR, como o PO apontou: senão o produto contradiz o código.
- Peso `heavy`: 8 ACs e bem mais de 8 arquivos.
- Se o `.git` dos worktrees for só leitura na sandbox do Codex, o card para em `blocked` em vez de liberar escrita fora das raízes: a sandbox é parte da barreira do AC-2.

## Open questions
- **Dependência:** marcar #149 como "Blocked by" deste card no GitHub (recomendado) ou só aprovar depois do merge do #149 — sem isso o develop pode começar sem o contrato do adaptador.
