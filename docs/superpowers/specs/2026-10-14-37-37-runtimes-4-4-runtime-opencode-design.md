# #37/37 Runtimes 4/4: runtime opencode — spec

**Issue:** #152 · **Branch:** `feat/152-37-37-runtimes-4-4-runtime-opencode` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** o `provider` de #151 só serve endpoints com a Responses API, porque o Codex exige isso; quem tem um endpoint próprio que só serve chat completions (o caso comum de vLLM, Ollama, LM Studio e gateways de empresa) não consegue rodar a fábrica. Falta um runtime `opencode` (v2) que leve um card de refine a validate com os mesmos gates, custo, pausa no limite, doctor e mensagens do dono.
**Audience:** outros desenvolvedores que instalam o plugin (e o dono, quando roda em modelos próprios).
**Acceptance criteria**
- **AC-1** — Dado `runtime: opencode` e um `opencode` falso que registra argv, stdin, cwd e ambiente, quando o card de exemplo passa por refine → develop → validate, então cada etapa roda `opencode run --standalone --auto --agent sf-<etapa> --format json` no `control` com `Card: #<n>` no stdin, os três `== end` têm `outcome=ok` e o card chega a Validation.
- **AC-2** — Dado esse `opencode` falso, quando uma etapa roda, então o ambiente traz `OPENCODE_CONFIG_DIR` da fábrica e `OPENCODE_DISABLE_PROJECT_CONFIG=1`, e as permissões em `OPENCODE_CONFIG_CONTENT` negam `external_directory` fora dos worktrees, `tmp` e `reviews` do projeto, `edit` em `~/.shipfloor/factory` e `webfetch`/`websearch`.
- **AC-3** — Dado `shipfloor install` com `runtime.models.agents` preenchido, quando termina (e quando roda de novo), então `~/.shipfloor/runtimes/opencode/` tem `opencode.json` com `"update": "disable"`, um `agents/sf-<etapa>.md` primário por etapa gerado de `skills/`, um subagente por arquivo de `agents/` com o `model` configurado, e a segunda execução não muda nada.
- **AC-4** — Dados `runtime.models` e `runtime.ladder` (ou `provider.models`/`provider.ladder`) com nomes `provider/modelo`, quando o develop roda de novo depois de um gate que falhou, então a linha leva `-m <modelo da etapa>` e sobe um degrau da escada; sem escada não sobe; sem modelo, a linha vai sem `-m`.
- **AC-5** — Dado o `provider` de #151 e um servidor falso que só serve `/v1/models` e `/v1/chat/completions`, quando uma etapa roda, então o config gerado aponta o provider `openai-compatible` para o `base_url`, `experimental.policies` libera só ele, a chave chega só por `{env:<api_key_env>}`, e o ambiente traz `OPENCODE_DISABLE_MODELS_FETCH=1` e `OPENCODE_DISABLE_AUTOUPDATE=1`.
- **AC-6** — Dado um log com um evento `error` de tipo `provider.quota` ou `provider.rate-limit`, quando o `outcome` do adaptador classifica, então o `== end` tem `outcome=usage_limit` e novas execuções esperam como no limite atual; outro erro com exit 1 dá `outcome=fail`.
- **AC-7** — Dado um `opencode.db` com uma sessão `sf-develop` e um subagente, quando o dashboard abre, então Sessions mostra a sessão, o subagente e os tokens por modelo, o Live mostra falas e ferramentas, e o custo vem do `prices.yml`, senão do `cost` > 0 do opencode, senão `$ ?` com os tokens (nunca `$0`); uma mensagem do dono enviada durante a execução chega ao agente e aparece como `owner`.
- **AC-8** — Dado `shipfloor doctor` com `runtime: opencode`, quando roda, então dá `FAIL` com instrução de migração para o opencode 1.x, `FAIL` para config gerado ausente e, com `provider`, para endpoint sem `/v1/chat/completions` (mais as checagens de #151 com `ok`/`FAIL`); com a v2 e tudo gerado, linhas `ok`.
**Out of scope:** o opencode 1.x (`opencode-ai`); etapas como `/comando` em vez de agente primário; o config pessoal do dono (`~/.config/opencode`) e o `.opencode/`/`opencode.json` do repositório (os caminhos proibidos já vêm de #149 AC-6); a descoberta automática de Ollama/LM Studio/vLLM sem `provider` explícito; plugins do opencode buscados no npm; isolar o `shell` além das permissões (os gates seguem como barreira); a execução com o opencode de verdade (registrada no PR, não é critério automatizado); mudanças no `claude-code` e no `codex`.
**Product fit:** serve ao princípio 2 (os gates e as permissões geradas pela fábrica valem, seja qual for o agente) e ao 3 (custo medido da base de sessões do opencode; sem preço, `$ ?` e não zero). Tensão com o Positioning: "custo medido dos transcripts do Claude Code, não do que o agente reporta" — aqui a fonte é o `opencode.db`, e o fallback para o `cost` do opencode é um número calculado pelo CLI, não pelo agente, mas não pelo `prices.yml`; o Positioning (já ampliado por #150 para "cada runtime") deve dizer que, sem preço na tabela, vale o custo calculado pelo runtime, sempre como estimativa.
**Touches UI:** no (Sessions, Live, `$ ?` e campo de modelo livre vêm de #150; aqui só os dados do opencode entram neles)

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Pré-requisito:** o contrato de #149 (`scripts/runtimes/`, `command`/`outcome`/`doctor`/`TRAILER`, `outcome=` na linha `== end`, `runtimes.sessions`, cache `version: 2`), o `runtime.models`/`runtime.ladder` e os marcadores `<!-- rt:… -->` de #150, e o `runtime.provider` e o `scripts/runtimes/provider.py` de #151 na `main`. O develop só começa depois de #151. Camada única: `factory`.

**Contratos tocados**
- Registro: `scripts/runtimes/__init__.py` `NAMES += ("opencode",)`.
- Config (`scripts/shipfloor_config.py`, `runtime_problems`): com runtime `opencode`, todo nome em `runtime.models`/`runtime.ladder`/`provider.models`/`provider.ladder` precisa casar `^[A-Za-z0-9._:@-]+/[A-Za-z0-9._:/@-]+$` (`provider/modelo`); o resolvedor de modelos e a escada são os de #150/#151, sem mudança.
- Sessão sem arquivo: o `id` de uma sessão do opencode é `<caminho do opencode.db>#<session id>` e o `stamp` é o `updated_at`; o cache de #149 já chaveia por `runtime:id` + `stamp`, então o contrato não muda.

**`scripts/runtimes/opencode.py` (novo, contrato de #149)**
- `NAME="opencode"`, `BINARY` (de `SHIPFLOOR_OPENCODE`, padrão `opencode`), `MODELS=()`, `LADDER=()`, `TRAILER="Co-Authored-By: opencode <noreply@opencode.ai>"`, `CONFIG_DIR` (`SHIPFLOOR_OPENCODE_HOME` ou `~/.shipfloor/runtimes/opencode`).
- `command(run) -> (argv, envs, stdin)`:
  - argv `opencode run --standalone --auto --agent sf-<etapa> --format json [-m <modelo>]`; stdin `Card: #<n>\n`; o cwd e o `PWD` já são o `control` (`dispatch._work`).
  - envs: `OPENCODE_CONFIG_DIR`, `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `OPENCODE_DISABLE_MODELS_FETCH=1`, `OPENCODE_DISABLE_AUTOUPDATE=1` e `OPENCODE_CONFIG_CONTENT` = JSON de `run_config(run)`.
  - `run_config`: `permissions` na ordem da issue §2, com `run.write` (worktrees, `tmp`, `reviews`) nos `allow` de `external_directory`, `run.read` (`~/.shipfloor/factory`, `reports-wt`) como `external_directory` allow seguido de `edit` deny no mesmo caminho, e `webfetch`/`websearch` deny por último; com provider, `providers.sf` (`package: "@opencode/ai/providers/openai-compatible"`, `settings.baseURL`, `settings.apiKey: "{env:<api_key_env>}"`, `models.<id>` com `capabilities.tools: true`) e `experimental.policies` com `provider.use: ["sf"]`.
- `outcome(rc, block)`: `usage_limit` se uma linha JSON do trecho tem `type: "error"` e `error.type` em `provider.quota`/`provider.rate-limit`; senão `ok` com `rc == 0`, `fail` caso contrário.
- `doctor()`: `opencode --version` ≥ 2 (1.x → `FAIL opencode: 1.x não é suportado; instale @opencode/cli 2.x`); `opencode.json` e `agents/sf-*.md` gerados; com provider, as checagens de `provider.check` (#151) trocando `/responses` por `POST /chat/completions` (`max_tokens: 1`); sem provider, `opencode auth list` mostra credencial para o provider do modelo.
- Custo: `data_dir()` (`OPENCODE_DB`, senão `~/.local/share/opencode/opencode.db`); `session_files(data_dir, slug)` lê `session_v2` com `sqlite3` em `file:…?mode=ro` (`uri=True`), `directory` = `<home>/control` e `parent_id` nulo, subagentes pelo `parent_id`; `parse` (etapa do `agent` `sf-<etapa>`, card de `Card: #<n>` na primeira mensagem, tokens por modelo de `session_message.data`: `input`, `output`, `reasoning` somado ao output, `cache.read`, `cache.write`; `cost` da sessão guardado à parte); `events` (texto → `says`, ferramenta → comando, texto do inbox → `owner`). Banco ausente ou travado → nenhuma sessão, sem erro.

**`scripts/runtimes/opencode_gen.py` (novo), chamado por `cmd_install`** (`scripts/shipfloor_core/cli.py`)
- Grava em `CONFIG_DIR`: `opencode.json` (`{"update": "disable"}`; só o que não varia por projeto), `agents/sf-<etapa>.md` (`mode: primary`, `description`, corpo = `skills/<etapa>/SKILL.md` sem frontmatter, com os blocos `<!-- rt:opencode -->` expandidos pelo mesmo expansor de #150 e ferramentas `read`/`edit`/`glob`/`grep`/`shell`/`subagent`), `agents/<papel>.md` (`mode: subagent`, `model` de `runtime.models.agents` quando houver) e `plugins/sf-inbox.ts` (cópia de `templates/opencode/sf-inbox.ts`). Idempotente: só reescreve quando o conteúdo muda.
- O corpo de cada etapa abre mandando ler o `CLAUDE.md` e o `AGENTS.md` do projeto (o config isolado desliga a leitura automática) e ler `<SHIPFLOOR_RUN_LOCK>/inbox` a partir de `inbox.lead` no começo de cada passo numerado (plano B de #150).

**Mensagens do dono:** `templates/opencode/sf-inbox.ts` (sem imports de npm) em `ctx.tool.hook("execute.after")` lê `$SHIPFLOOR_RUN_LOCK/inbox`, avança o contador `inbox.<agente>` como o `inbox_hook.py` e injeta `INTRO` + texto com `ctx.session.synthetic`. O plano B no corpo da etapa garante o AC-7 se o plugin não entregar.

**Telemetria (#255):** `telemetry.run_agent` entende o stream-json do Claude; para outro runtime, `dispatch._work` passa `stream=False` e o stdout vai ao log linha a linha, sem parse nem `events.jsonl`/`runs.jsonl`. O `outcome` lê o JSON bruto do log.

**Arquivos:** `scripts/runtimes/{__init__,opencode,opencode_gen,provider}.py`, `templates/opencode/sf-inbox.ts` (novo), `scripts/shipfloor_config.py`, `scripts/shipfloor_core/{dispatch,telemetry,cli}.py`, `skills/{refine,develop,validate,deploy}/SKILL.md` e `agents/*.md` (blocos `rt:opencode`), `docs/configuration.md` (instalar o opencode v2, escolher provider, `codex` × `opencode`), `docs/install.md`. Testes nas suítes abaixo, com um `opencode` falso em `scripts/test/` (grava argv, stdin, cwd e env; escreve eventos JSON e um `opencode.db` de exemplo) e o `fake_llm.py` de #151 com modo `chat-only`.

**Migração:** nenhuma. Sem `runtime: opencode`, nada muda.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/dispatch_cycle.py` |
| AC-2 | factory | `scripts/test/py/dispatch_launch.py` |
| AC-3 | factory | `scripts/test/py/install_copy.py` |
| AC-4 | factory | `scripts/test/py/dispatch_launch.py` |
| AC-5 | factory | `scripts/test/py/dispatch_launch.py` |
| AC-6 | factory | `scripts/test/py/dispatch_cycle.py` |
| AC-7 | factory | `scripts/test/py/dispatch_cost.py` |
| AC-8 | factory | `scripts/test/py/cli_doctor.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Adaptador em Python (`scripts/runtimes/opencode.py` com `command`/`outcome`/`doctor`), não `opencode.sh` com `rt_run`: segue o contrato aprovado de #149; #150 e #151 ainda descrevem `codex.sh` e devem se alinhar a ele.
- Provider, permissões e `experimental.policies` vão no `OPENCODE_CONFIG_CONTENT` de cada execução, não no `opencode.json` gerado: o `factory.yml` sobrepõe o provider por projeto e os caminhos variam por projeto; o `opencode.json` guarda só o que é da máquina.
- A leitura de `~/.shipfloor/factory` e do `reports-wt` é `external_directory` allow seguido de `edit` deny no mesmo caminho: com "a última regra vence", isso libera ler e nega escrever (resolve o ⚠ da §2).
- Etapa como agente primário `sf-<etapa>`, nunca `/comando` (dúvida 1): funciona com ou sem a expansão de comandos no `run`.
- Custo: `prices.yml` primeiro, senão o `cost` > 0 do opencode, senão `$ ?` (dúvida 2, como o PO e a proposta da issue); ver Open questions.
- Mensagem do dono: plugin `synthetic` e plano B no corpo da etapa, os dois gerados (dúvida 3): o AC-7 aceita qualquer um, e a execução real no PR diz se o plugin entrega.
- O contrato `session_files` de #149 não muda: `id` = `opencode.db#<session>` e `stamp` = `updated_at` cabem na chave `runtime:id` + `stamp` do cache.
- Telemetria de #255 só para o `claude-code`: o parser é do stream-json do Claude; o resumo em `runs.jsonl` para o opencode fica para outro card.
- `reasoning` somado ao `output` no custo: o opencode cobra o raciocínio como saída.
- Sem suíte nova: os casos entram em `dispatch_launch.py`, `dispatch_cycle.py`, `dispatch_cost.py`, `install_copy.py` e `cli_doctor.py`, como em #150.
- O plugin TypeScript não é testado em processo (não há runtime de TS na camada); o teste confere que ele é gerado, e a execução real no PR confere a entrega.
- Peso `heavy`: 8 ACs e mais de 8 arquivos.
- O card deve ficar "Blocked by #151" no GitHub, porque é por essa relação que o dispatcher segura um card.

## Open questions
- **Custo sem preço:** A, usar o `cost` do opencode quando o `prices.yml` não tem o modelo (recommended), ou B, só `prices.yml`, senão `$ ?` — A mostra US$ calculado pelo CLI (estimativa, conta no limite de custo e exige ajustar o Positioning); B mantém uma fonte só e o AC-7 perde o passo do meio.
