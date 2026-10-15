# Plano — #151 modelos self-hosted pelo codex

Spec: `docs/superpowers/specs/2026-10-14-36-37-runtimes-3-4-modelos-self-hosted-design.md`.

**Ajuste ao spec:** o spec foi escrito antes de #149/#150 entrarem e fala em `codex.sh` e `runtime.test.sh`. Na `main` o
runtime é Python: `scripts/runtimes/codex.py` (`command(run)`, `outcome(rc, block)`, `doctor()`), a suíte de runtimes é
`scripts/test/py/runtime.py` (chamada por `config.test.sh` com `py_suite runtime`) e o `-m` vem de
`runtime_stage_models()`. Onde o spec diz `codex.sh`/`runtime.test.sh`, vale `codex.py`/`py/runtime.py`.

Única camada: `factory` (agente `engineer`).

## Tarefas

1. **Config** (`scripts/shipfloor_config.py`)
   - `runtime_problems`: aceitar `provider` = `{base_url, api_key_env?, models?, ladder?}` (chave desconhecida → inválido,
     mensagem com o caminho da chave). `base_url` `^https?://[^\s"'\\]+$`; `api_key_env` `^[A-Za-z_][A-Za-z0-9_]*$`;
     `models`/`ladder` pelos validadores de `runtime.models`/`runtime.ladder`; nome de modelo `^[A-Za-z0-9._:/@-]+$`.
   - `runtime_setting(..., "provider")`: projeto sobre máquina, chave a chave (`models` mescla como hoje; `ladder` e
     escalares substituem).
   - Com provider efetivo, `runtime_stage_models` e `model-up` usam `provider.models`/`provider.ladder` e ignoram os de
     `runtime`. Vale também para o que alimenta `agents` no `_generate_codex_home` (cli.py) e `dashboard.py:1007`.
   - Subcomando `machine provider [<factory.yml>]`: `base_url` NUL `api_key_env` NUL (nome, nunca o valor); vazio sem
     provider.
2. **`scripts/runtimes/provider.py`** (novo, stdlib): `codex_args(base_url, key_env)`, `check(base_url, models, key_env)`
   e CLI `python3 -I provider.py codex-args|check`, como no spec (switches de rede por `-c`, `wire_api="responses"`,
   timeout 5 s, nenhuma linha com cabeçalho, corpo ou valor da chave).
3. **`scripts/runtimes/codex.py` + dispatch**
   - `command(run)`: com `run["provider"]`, acrescenta `codex_args`. O dispatch lê `machine provider` e passa em `run`.
   - Variável de `api_key_env` ausente no ambiente do dispatcher: `provider: <VAR> is not set` no log, run falha sem
     chamar o `codex`; o valor só passa pelo ambiente herdado.
   - `outcome`: `LIMIT` ganha `rate limit exceeded` (sem distinção de maiúsculas).
   - `doctor()`: com provider, linhas de `provider.check` (`ok`/`FAIL` distintas) e o aviso de que `runtime.models` /
     `runtime.ladder` são ignorados.
4. **Teste de apoio** `scripts/test/fake_llm.py` (novo): `http.server` em `127.0.0.1:0`, `/v1/models` e `/v1/responses`,
   modos `down`, `no-responses` (404), `429`; grava o `Authorization` recebido.
5. **Docs**: `docs/configuration.md` (Runtime → Modelos próprios) e uma linha no `README.md`.

Dependências: 1 → 2 → 3; 4 é de QA (apoio dos testes); 5 depois de 3.

## Testes de aceitação (QA, antes da implementação)

AC-1 `py/config_machine.py` (e `config_project.py` para o `factory.yml`); AC-2..AC-5 e AC-8 em `py/runtime.py` (a suíte
de runtimes que já existe, em vez de `runtime.test.sh`); AC-6 `py/dispatch_cost.py`; AC-7 `py/cli_doctor.py`.
