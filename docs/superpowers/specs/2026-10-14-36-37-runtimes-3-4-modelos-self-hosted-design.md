# #36/37 Runtimes 3/4: modelos self-hosted (endpoint compatível com OpenAI) pelo codex — spec

**Issue:** #151 · **Branch:** `feat/151-36-37-runtimes-3-4-modelos-self-hosted` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** Quem não pode (ou não quer) mandar código para um provedor de LLM na internet não consegue rodar a fábrica: o runtime `codex` (#150) só fala com a OpenAI. Falta apontar o Codex para um endpoint próprio compatível com OpenAI (vLLM, Ollama, LM Studio, endpoint da empresa), sem tráfego para provedores de LLM e sem vazar a chave.
**Audience:** outros desenvolvedores que instalam o plugin (e o dono, quando roda em modelos próprios).
**Acceptance criteria**
- **AC-1** — Given um `runtime.provider` com `base_url` que não é `http(s)://…`, ou `api_key_env` que não é um nome de variável, ou `models`/`ladder` fora do formato de `runtime.models`, em `config.yml` ou `factory.yml`, when o config é lido, then ele é inválido com mensagem que nomeia a chave, e o dispatch para com exit 2.
- **AC-2** — Given `provider` configurado e um `codex` falso que registra argumentos e ambiente, when o `rt_run` roda uma etapa, then a linha leva `-c model_providers.sf={…base_url…,env_key=<api_key_env>,wire_api="responses"}`, `-c model_provider=sf`, `-m <modelo da etapa em provider.models>` e, por `-c`, os switches de analytics, otel, feedback, update check e web search desligados; o valor da chave chega só pelo ambiente.
- **AC-3** — Given `provider` com `factory.yml` sobrepondo o `config.yml` chave a chave e `runtime.models`/`runtime.ladder` também preenchidos, when o dispatch resolve modelos, then valem os do `provider` (do projeto sobre a máquina), os de `runtime` são ignorados, e depois de um gate que falhou o develop sobe um degrau de `provider.ladder`.
- **AC-4** — Given um `codex` falso e um servidor falso de `/v1/models` e `/v1/responses`, when um card de exemplo passa por refine → develop → validate com `provider`, then os três `== end` têm `outcome=ok` e o card chega a Validation como num runtime em nuvem.
- **AC-5** — Given uma execução cujo log termina com `exceeded retry limit, last status: 429` ou `rate limit exceeded`, when o `rt_outcome` classifica, then a linha `== end` tem `outcome=usage_limit` e as novas execuções esperam como no limite de uso atual.
- **AC-6** — Given uma execução com um modelo self-hosted sem preço em `prices.yml`, when o dashboard mostra o custo, then aparece `$ ?` com os tokens (nunca `$0`) e o limite de custo por card e por dia não a conta; com o modelo em `prices.yml`, ela passa a ser contada.
- **AC-7** — Given `provider` configurado, when roda `shipfloor doctor`, then há uma linha `FAIL` distinta para cada caso: endpoint fora do ar, modelo configurado ausente de `GET /models`, variável de `api_key_env` ausente, e endpoint sem `/responses` (esta sugerindo o opencode); com tudo certo, linhas `ok`; com `runtime.models` também preenchido, um aviso de que é ignorado.
- **AC-8** — Given `api_key_env` aponta para uma variável com um valor conhecido, when uma etapa roda e o doctor roda, then esse valor não aparece em nenhum arquivo sob `~/.shipfloor` (config, logs, `CODEX_HOME`, rollouts) nem na saída do doctor.
**Out of scope:** o opencode e endpoints só de chat completions (#152); o atalho `--oss`/`--local-provider` (só o `provider` explícito, um caminho a manter); `provider` para o `claude-code`; isolar a rede da sandbox (decidido em #150: a rede segue ligada); a execução manual com um modelo real (vai registrada no PR, não é critério automatizado); garantir versões mínimas de vLLM/Ollama/LM Studio além de documentá-las.
**Product fit:** serve ao princípio 3 (números exatos e com fonte; estimativa diz que é): sem preço, o custo vira `$ ?` e não um zero falso, e não entra no limite. Reforça o compromisso de que nada sai da máquina sem o dono escolher. Tensão com o Positioning ("custo medido pelos transcripts do Claude Code"), que já é ampliado por #149/#150 para os transcripts de cada runtime; este card não acrescenta contradição nova, mas o `PRODUCT.md` deve ser atualizado quando a série entrar.
**Touches UI:** no (o `$ ?` com tokens vem de #150; aqui só é verificado para modelos self-hosted)

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

**Pré-requisito:** constrói sobre o contrato de #149 (`scripts/runtimes/`, `rt_run`/`rt_outcome`/`rt_doctor`, `outcome=` na linha `== end`) e sobre o runtime `codex` de #150 (`scripts/runtimes/codex.sh`, `runtime.models`/`runtime.ladder`). Nenhum dos dois está na `main` hoje; o develop só começa depois que #150 entrar.

**Contratos**
- Config (`config.yml` e `factory.yml`, chave a chave): `runtime.provider` = `{base_url, api_key_env?, models?, ladder?}`. Chave desconhecida dentro de `provider` → inválido.
- Validação, em `runtime_problems()` (#149) de `shipfloor_config.py`:
  - `base_url`: `^https?://[^\s"'\\]+$` (sem aspas nem espaço, porque vai dentro de uma tabela TOML inline no `-c`);
  - `api_key_env`: `^[A-Za-z_][A-Za-z0-9_]*$`;
  - `models`/`ladder`: o mesmo validador de `runtime.models`/`runtime.ladder` (#150), e cada nome de modelo em `^[A-Za-z0-9._:/@-]+$`.
- Resolução de modelos (o resolvedor que #150 cria para `runtime.models`): com `provider`, valem `provider.models` e `provider.ladder`; os de `runtime` são ignorados. Vale para o modelo da etapa (`-m`), para a subida da escada e para o `agent models:` do `describe`.
- Nova consulta `shipfloor_config.py machine provider [<factory.yml>]`: imprime `base_url` e `api_key_env` (o nome, nunca o valor) do provider efetivo, separados por NUL; vazio sem provider. O `codex.sh` e o doctor leem por ela.

**`scripts/runtimes/provider.py` (novo, stdlib)** — compartilhado com o opencode (#152):
- `codex_args(base_url, key_env) -> [str]`: os `-c` do provider e os switches de rede:
  - `model_providers.sf={name="sf",base_url="…",env_key="<VAR>",wire_api="responses",requires_openai_auth=false,supports_websockets=false}` (sem `env_key` quando não há `api_key_env`);
  - `model_provider=sf`;
  - `analytics.enabled=false`, `otel.metrics_exporter="none"`, `feedback.enabled=false`, `check_for_update_on_startup=false`, `web_search="disabled"`.
- `check(base_url, models, key_env) -> [(ok|FAIL, texto)]`, com `urllib` e timeout de 5 s:
  - a variável de `key_env` existe (sem ler o valor para a saída);
  - `GET <base_url>/models` responde, e cada modelo configurado está em `data[].id`;
  - `POST <base_url>/responses` com `{"model": <primeiro modelo>, "input": "ping", "max_output_tokens": 1}`: 404/405 → `FAIL … sem /v1/responses; use o runtime opencode (#152)`.
  - Nenhuma linha imprime cabeçalho, corpo de resposta ou o valor da chave.
- CLI: `python3 -I provider.py codex-args|check …`, para o `codex.sh` chamar.

**`scripts/runtimes/codex.sh` (de #150)**
- `rt_run`: com provider, acrescenta os argumentos de `provider.py codex-args` ao `codex exec`. O `-m` já vem de `RT_MODEL`, resolvido acima. Com `api_key_env` e a variável ausente no ambiente do dispatcher, escreve `provider: <VAR> is not set` no `RT_LOG` e devolve 1 (sem chamar o `codex`). O valor só passa pelo ambiente herdado.
- `rt_outcome`: o regex de `usage_limit` ganha `rate limit exceeded` (sem distinção de maiúsculas); `exceeded retry limit, last status: 429` já vem de #150.
- `rt_doctor`: com provider, acrescenta as linhas de `provider.py check` e o aviso `runtime.models/runtime.ladder ignorados: há provider`.

**Custo:** nenhuma mudança de código esperada. `dashboard_cost.cost()` já devolve `None` para um modelo sem preço, `spend()` não soma isso no dia e `over()` não bloqueia um total `None`. O `$ ?` com tokens vem de #150 (nome completo do modelo). Aqui só se fixa o comportamento por teste, com um nome self-hosted.

**Teste:** `scripts/test/fake_llm.py` (novo): `http.server` em `127.0.0.1:0` com `/v1/models` e `/v1/responses`, e modos `down`, `no-responses` (404) e `429`. Grava o `Authorization` recebido para os testes conferirem a chave.

**Docs**
- `docs/configuration.md`, seção **Runtime → Modelos próprios**:
  - exemplos de vLLM, Ollama (11434), LM Studio (1234) e um endpoint corporativo, com as versões que servem `/v1/responses` conferidas na implementação;
  - o que o modelo precisa ter: tool calling, contexto grande (mais de 30k tokens) e a Responses API;
  - a regra do `$ ?` e do limite de custo, e como pôr preço em `~/.shipfloor/prices.yml`;
  - como dar a variável da chave ao dispatcher agendado (`systemctl --user set-environment`, `launchctl setenv`), nunca num arquivo em `~/.shipfloor`.
- `README.md`: uma linha em "Quick start" apontando para essa seção.

**Arquivos:** `scripts/shipfloor_config.py`, `scripts/runtimes/provider.py` (novo), `scripts/runtimes/codex.sh`, `scripts/test/fake_llm.py` (novo), `docs/configuration.md` e `README.md`. Testes em `scripts/test/py/config_machine.py`, `scripts/test/py/config_project.py`, `scripts/test/runtime.test.sh`, `scripts/test/py/dispatch_cost.py` e `scripts/test/py/cli_doctor.py`. Todos são da camada `factory`.

**Migração:** nenhuma. Sem `provider`, nada muda.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/config_machine.py` |
| AC-2 | factory | `scripts/test/runtime.test.sh` |
| AC-3 | factory | `scripts/test/runtime.test.sh` |
| AC-4 | factory | `scripts/test/runtime.test.sh` |
| AC-5 | factory | `scripts/test/runtime.test.sh` |
| AC-6 | factory | `scripts/test/py/dispatch_cost.py` |
| AC-7 | factory | `scripts/test/py/cli_doctor.py` |
| AC-8 | factory | `scripts/test/runtime.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Ordem: o develop só começa com #150 na `main`. O card deve ficar "Blocked by #150" no GitHub, porque é por essa relação que o dispatcher segura um card.
- Só o `provider` explícito, sem `--oss`: um caminho só, e os switches de rede valem igual para Ollama e LM Studio (responde à dúvida 2 da issue).
- As versões de vLLM, Ollama e LM Studio com `/v1/responses` (dúvida 1) são pesquisadas e documentadas na implementação. Não decidem o desenho, porque o doctor detecta o endpoint sem `/responses`.
- O catálogo remoto de modelos sem rede (dúvida 3) é conferido na execução manual registrada no PR. Se ele atrasar cada execução, o switch que o desliga entra em `codex_args`.
- `provider.py` em Python, não em Bash: o doctor precisa de HTTP com timeout e de JSON, e #152 reaproveita o mesmo módulo.
- O `rt_run` falha logo quando a variável da chave falta: o dispatcher agendado não herda o ambiente do shell, e um erro explícito é melhor do que um 401 do endpoint.
- Base_url e nomes de modelo têm um regex restrito: eles entram numa tabela TOML inline num `-c`, e uma aspa quebraria o parse do Codex.
- O isolamento é verificado no teste pelos switches na linha de comando (AC-2), não bloqueando a rede: o teste roda em processo, sem firewall. O proxy que registra hosts fica na execução manual do PR.
- Os testes de runtime vão em `scripts/test/runtime.test.sh`, a suíte que #149 cria para o contrato. Se ela for só um invólucro de `py_suite`, eles entram no módulo Python que ela chama.
- `scripts/test/fake_llm.py` é um apoio de teste novo: nenhum servidor falso de HTTP existe hoje em `scripts/test`.
- O custo não tem mudança de código: as regras de `dashboard_cost.py` já tratam um modelo sem preço como desconhecido, e o teste fixa isso.
- Sem seção de segurança: a issue não tem o rótulo `cybersec`. A chave fica coberta pelo AC-8 e pelo regex de `api_key_env`.
- O `PRODUCT.md`, que ainda diz que o custo vem dos transcripts do Claude Code, é atualizado quando a série #149–#152 entrar. Ele está fora do escopo deste card.

## Open questions
- none
