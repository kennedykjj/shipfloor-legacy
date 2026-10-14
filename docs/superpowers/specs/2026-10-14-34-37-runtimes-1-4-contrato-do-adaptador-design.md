# #34/37 Runtimes 1/4: contrato do adaptador, com o claude-code atrás dele — spec

**Issue:** #149 · **Branch:** `feat/149-34-37-runtimes-1-4-contrato-do-adaptador` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** tudo o que fala com o agente (início da execução, limite de uso, custo, doctor, trailer dos commits) está espalhado e amarrado ao Claude Code. Isso impede entrar outro CLI (#150–#152) sem reescrever a fábrica. Esta fase põe tudo atrás de um contrato de runtime, e o comportamento do `claude-code` não muda.
**Audience:** o dono da fábrica e os outros desenvolvedores que instalam o plugin.
**Acceptance criteria**
- **AC-1** — Dado um `config.yml` ou `factory.yml` com runtime desconhecido, etapa desconhecida ou chave fora de `default`/`stages`, quando o dispatch roda, então o config é inválido, a mensagem lista os runtimes conhecidos e o dispatch sai com exit 2 sem cair para outro CLI. Com `runtime` em string ou em mapa, o `factory.yml` sobrepõe o `config.yml` chave a chave (`shipfloor_config.py machine runtimes`).
- **AC-2** — Dado um config sem `runtime` ou com `runtime: claude-code`, quando uma etapa é iniciada, então a linha de comando do `claude`, as variáveis de ambiente e o trailer `Co-Authored-By` dos commits de `deploy.sh`/`report.sh` são idênticos aos de hoje, e `dispatch-launch`, `dispatch-models`, `dispatch-weight` e `dispatch-stepup` passam sem mudança.
- **AC-3** — Dada uma execução concluída, quando o log é lido, então a linha `== start` traz `runtime=<nome>` e a linha `== end` termina em `outcome=ok|fail|usage_limit`. Um `outcome=ok` num log que cita o texto do limite não pausa; um log antigo sem `outcome=`, com o texto, pausa (dispatch, dispatcher agendado, dashboard e health).
- **AC-4** — Dados transcripts e um `cost-cache.json` de antes da mudança, quando o dashboard abre, então custo, Live e Sessions mostram o mesmo de antes, o cache antigo é relido ou descartado sem erro, e `dashboard*.test.sh`, `dispatch-cost.test.sh` e `health.test.sh` ficam verdes.
- **AC-5** — Dado o `claude` no PATH e nenhum runtime configurado, quando o dono roda `shipfloor doctor`, então a linha `ok   claude-code: claude` aparece no lugar de `ok   claude`. O doctor checa só os runtimes em uso (`config.yml` mais o `factory.yml` de cada projeto registrado).
- **AC-6** — Dado um diff que toca `.codex/x`, `.opencode/x`, `.agents/x`, `AGENTS.md`, `AGENTS.override.md`, `opencode.json` ou `opencode.jsonc`, quando o gate `forbidden` (e o workflow `factory-guard`) roda, então o diff é barrado (`config.test.sh`, `gate-scope.test.sh`).
- **AC-7** — Dado um `shipfloor install`, quando ele termina, então `scripts/runtimes/` está na cópia instalada sem `__pycache__` (teste `install-*`), e o `hygiene.test.sh` aceita o marcador "legacy" em `scripts/runtimes/`.
- **AC-8** — Dado o teste novo `scripts/test/runtime.test.sh`, quando ele roda, então cobre config (nenhum runtime, string, mapa, projeto sobre a máquina, inválidos), linha de comando, `outcome` e pausa, e a regra de pausa do dashboard, e passa.
**Out of scope:** qualquer runtime além do `claude-code` (#150, #151, #152); as chaves `models`, `ladder` e `provider` do `runtime`; gerar etapas e agentes no formato de outro runtime; trocar o texto das mensagens de limite (`shipfloor_notify.py`, `lang/*`); qualquer mudança visual no dashboard; corrigir `dispatch.test.sh` e `notify-channels.test.sh`, que já falham na `main`.
**Product fit:** serve ao princípio 2 (gates determinísticos acima da palavra do agente): a pausa por limite passa a ler um marcador gravado pelo adaptador, não o texto do CLI, e os caminhos proibidos passam a cobrir as instruções e permissões de todos os runtimes. Serve também ao princípio 3: o custo continua exato e com fonte, agora por um contrato por runtime. A Positioning hoje diz que o custo vem "dos transcripts do Claude Code"; esta fase não contradiz isso, porque só o `claude-code` existe, mas o épico #146 vai exigir trocar essa frase quando #150 entrar.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Camada única: `factory`. O dispatch, o dispatcher agendado e o CLI já são Python (`shipfloor_core/`); `dispatch.sh` e `shipfloor-dispatch.sh` são wrappers finos. Por isso o adaptador é um módulo Python, não um `.sh` com `source` (ver Decisions).

**Pacote novo `scripts/runtimes/`**
- `__init__.py`: `NAMES = ("claude-code",)` (o primeiro é o padrão); `get(name)` devolve o módulo; `sessions(slug, read, dirs)` junta as sessões de todos os runtimes com `runtime`, `id`, `path`, `subagent_paths`; `TOKEN_KINDS` (vindo de `dashboard_cost.py`); `outcome_of(block)` e `usage_limited(block)`: a regra única de pausa (último trecho `== start` com `outcome=usage_limit` pausa; trecho sem `outcome=` pausa pelo texto antigo, marcado `legacy`).
- `claude_code.py` (contrato do runtime):
  - `NAME = "claude-code"`, `BINARY` (de `FACTORY_CLAUDE`, padrão `claude`), `MODELS`, `LADDER` (os valores de hoje de `shipfloor_config.py:533-534`), `TRAILER` (= `shipfloor_core.defaults.TRAILER`).
  - `command(run) -> (argv, envs, stdin)`: recebe `stage, issue, model, plugin, write: [..], read: [..], envs: [..], system_prompt` e devolve exatamente o argv/env/stdin que `dispatch.py:launch`+`supervise.agent` montam hoje (`-p --permission-mode acceptEdits`, `--add-dir` de cada `write`, `--setting-sources project,local`, `--strict-mcp-config`, `--plugin-dir`, `--allowedTools Read(//…/**)` de cada `read`, `--disallowedTools PowerShell`, `--append-system-prompt`, `--model` só quando há modelo; `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`; stdin `/sf:<etapa> <n>`), na mesma ordem.
  - `outcome(rc, block) -> "ok"|"fail"|"usage_limit"`: `usage_limit` se o trecho tem `hit your session limit`; senão `ok` se `rc == 0`, `fail` caso contrário.
  - `doctor() -> [(ok, "claude-code: claude")]`.
  - Custo (mudam de `dashboard_cost.py`): `COMMAND`, `text_of`, `doing`, `parse(session)` (= `parse_transcript`), `events(session)`, `data_dir()` (`CLAUDE_CONFIG_DIR` ou `~/.claude`), `session_files(data_dir, slug)` (a busca `projects/*-projects-<slug>-control/*.jsonl` mais `<id>/subagents/`), `stamp(session)` (tamanho + mtime).

**Arquivos alterados**
- `scripts/shipfloor_config.py`: `runtime_problems(raw, where)` chamado em `problems()` e em `machine_problems()`; aceita string ou mapa com só `default`/`stages`, etapas `refine|develop|validate|deploy`, nomes de `runtimes.NAMES`; a mensagem lista os runtimes conhecidos. Consulta nova `machine runtimes [<factory.yml>]`: 4 nomes separados por NUL, projeto sobre máquina chave a chave. `MODELS`/`MODEL_LADDER` passam a ser `claude_code.MODELS`/`LADDER` (mesmo valor). `BUILTIN_FORBIDDEN` ganha `^(\.codex/|\.opencode/|\.agents/)` e `^(AGENTS\.md|AGENTS\.override\.md|opencode\.jsonc?)$`. Importa `runtimes` pondo a pasta do script no `sys.path` (roda com `python -I`).
- `scripts/shipfloor_core/dispatch.py`: lê `machine runtimes` uma vez por ciclo junto com `stage-models`; `launch` monta o run por `runtimes.get(rt).command(...)`; o `spec` do `_detach` leva `runtime`, `argv`, `envs`, `stdin` no lugar de `claude`/`args`; `supervise` grava `runtime=<nome>` na linha `== start` (depois de `weight=`) e `_work` grava `outcome=<…>` no fim da linha `== end` (depois da data), calculado por `rt.outcome(rc, último trecho)`; `usage_limited` usa `runtimes.usage_limited`; `USAGE_LIMIT` sai daqui. `SHIPFLOOR_TRAILER` só entra no env quando o `TRAILER` do runtime difere do padrão (nunca nesta fase: env idêntico ao de hoje).
- `scripts/shipfloor_core/cycle.py`: `usage_limited(home)` usa `runtimes.usage_limited`.
- `scripts/shipfloor_core/deploy.py`, `scripts/shipfloor_core/report.py`: trailer = `os.environ.get("SHIPFLOOR_TRAILER") or TRAILER`.
- `scripts/shipfloor_core/cli.py` (`cmd_doctor`): `git`, `gh` e o `doctor()` de cada runtime em uso (união do `config.yml` com o `factory.yml` de cada projeto registrado; nenhum → `claude-code`), linha `ok   claude-code: claude` / `FAIL claude-code: claude not found`.
- `scripts/dashboard_cost.py`: reexporta `parse_transcript`, `events`, `TOKEN_KINDS` de `runtimes`; `project_sessions` usa `runtimes.sessions`; `Transcripts` (cache) passa a chavear por `runtime:id` + `stamp` e grava `"version": 2`; um `cost-cache.json` sem versão é descartado e reparseado, sem erro.
- `scripts/dashboard.py`: `Factory.sessions`, `Factory.session` e `Factory.transcript` só pelo contrato; `Factory.usage_limited` usa `runtimes.usage_limited` (o `shipfloor_health.py` herda). `RUN_LINE`/`STEPUP_LINE` continuam casando com as linhas novas.
- `templates/factory-guard.yml:26`: o mesmo regex novo do `BUILTIN_FORBIDDEN`.
- `.github/workflows/factory-guard.yml:26`: idem, **à mão pelo dono** (caminho proibido; ver Open questions).
- `scripts/test/hygiene.test.sh`: aceita `legacy` também em `scripts/runtimes/`.
- `docs/configuration.md`: seção **Runtime** (só `claude-code`); `README.md`: `claude` é o runtime padrão.
- Testes: `scripts/test/runtime.test.sh` + `scripts/test/py/runtime.py` (novos); casos novos em `py/dispatch_launch.py`, `py/dispatch_cost.py`, `py/cli_doctor.py`, `py/config_project.py`, `py/install_copy.py`.

**Contratos tocados**
- Linha de log: `== start /sf:<p> <n> <data> pid=<pid>[ model=<m>] weight=<w> runtime=<nome>`; `== end /sf:<p> <n> exit=<rc> <data> outcome=<ok|fail|usage_limit>` (a linha `== end … : no <control>` também ganha `outcome=fail`).
- `shipfloor_config.py machine runtimes [<factory.yml>]` (nova consulta).
- `cost-cache.json`: formato `version: 2`.
- Sem migração de dados: logs e cache antigos continuam lidos (logs) ou são descartados e refeitos (cache).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/runtime.py` |
| AC-2 | factory | `scripts/test/py/dispatch_launch.py` |
| AC-3 | factory | `scripts/test/py/runtime.py` |
| AC-4 | factory | `scripts/test/py/dispatch_cost.py` |
| AC-5 | factory | `scripts/test/py/cli_doctor.py` |
| AC-6 | factory | `scripts/test/py/config_project.py` |
| AC-7 | factory | `scripts/test/py/install_copy.py` |
| AC-8 | factory | `scripts/test/runtime.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Adaptador em Python (`scripts/runtimes/claude_code.py`), não em `scripts/runtimes/claude-code.sh`: desde #168/#169/#170 o dispatch, o ciclo e o CLI são Python e não há mais shell onde fazer `source`; o contrato (`command`, `outcome`, `doctor`, `TRAILER`) é o mesmo do issue.
- A regra de pausa mora em `runtimes.usage_limited`, não em `lib/project.sh`: os três leitores de hoje (`dispatch.py`, `cycle.py`, `dashboard.py`) são Python.
- Os testes `dispatch-models`, `dispatch-weight` e `dispatch-stepup` citados no AC-2 hoje são casos de `py/dispatch_launch.py` (atrás de `dispatch-launch.test.sh`), e o `gate-scope.test.sh` do AC-6 não existe mais: o barramento é testado em `py/config_project.py` (via `BUILTIN_FORBIDDEN`).
- Suite nova `py/runtime.py` + `runtime.test.sh`: o AC-8 pede esse arquivo e nenhuma suite cobre o pacote novo `scripts/runtimes/`.
- `SHIPFLOOR_TRAILER` só é exportado quando o trailer do runtime difere do padrão: assim o env do `claude-code` fica idêntico ao de hoje (AC-2).
- `cost-cache.json` antigo é descartado (sem campo `version`) em vez de convertido: reparsear custa um ciclo e evita código de migração.
- `outcome=usage_limit` tem prioridade sobre o exit code: um CLI que sai 0 ao bater no limite ainda pausa a fábrica.
- Peso `heavy`: mais de 8 arquivos na arquitetura e 8 ACs.

## Open questions
- **factory-guard do repo:** o dono atualiza `.github/workflows/factory-guard.yml:26` à mão com o regex novo (recommended) ou fica fora desta fase — caminho proibido para a fábrica; sem isso, o CI deste repo não barra `.codex/`, `AGENTS.md` etc.
