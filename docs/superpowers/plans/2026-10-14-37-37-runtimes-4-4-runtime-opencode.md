# Plano — runtime opencode (#152)

Camada única: `factory` (agente `engineer`). Modelo do adaptador: `scripts/runtimes/codex.py` e `codex_gen.py`.

## Tarefas

1. **Adaptador `opencode`** — `scripts/runtimes/opencode.py`, registro em `scripts/runtimes/__init__.py` (`NAMES`), validação `provider/modelo` em `scripts/shipfloor_config.py` (`runtime_problems`), `outcome=usage_limit` por evento `error`, `command` com argv/envs/`OPENCODE_CONFIG_CONTENT` (permissões e provider `openai-compatible`), ladder e `-m`. ACs 1, 2, 4, 5, 6. `scripts/shipfloor_core/dispatch.py` (`stream=False` para runtimes não-Claude, se ainda não for) e `telemetry.py`.
2. **Geração no install** — `scripts/runtimes/opencode_gen.py` chamado por `cmd_install` em `scripts/shipfloor_core/cli.py`; `templates/opencode/sf-inbox.ts`; blocos `<!-- rt:opencode -->` em `skills/*/SKILL.md` e `agents/*.md`. Idempotente. AC 3.
3. **Custo e sessões** — `data_dir`, `session_files`, `parse`, `events` sobre o `opencode.db` (sqlite3 somente leitura), custo `prices.yml` → `cost` > 0 → `$ ?`; mensagens do dono como `owner`. AC 7.
4. **Doctor** — `doctor()` do adaptador e integração em `shipfloor doctor` (`cli.py`): versão 2, config gerado, endpoint `/chat/completions`. AC 8.
5. **Docs** — `docs/configuration.md`, `docs/install.md`; ajuste do Positioning se citado.

Dependência: 1 → 2 → 3 → 4 → 5 (mesmo worktree, em sequência). Os testes vão em `dispatch_launch.py`, `dispatch_cycle.py`, `dispatch_cost.py`, `install_copy.py`, `cli_doctor.py`, com um `opencode` falso em `scripts/test/` e o `fake_llm.py` com modo `chat-only`.
