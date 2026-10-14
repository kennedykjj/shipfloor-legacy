# Plano — #149 Runtimes 1/4: contrato do adaptador, com o claude-code atrás dele

Spec: `docs/superpowers/specs/2026-10-14-34-37-runtimes-1-4-contrato-do-adaptador-design.md`

Camada única: `factory` (path `./`). As tarefas rodam em ordem, no mesmo worktree.

## Tarefas

1. **factory** · dono: `qa-engineer` · arquivos: `scripts/test/runtime.test.sh` (novo), `scripts/test/py/runtime.py` (novo), `scripts/test/py/dispatch_launch.py`, `scripts/test/py/dispatch_cost.py`, `scripts/test/py/cli_doctor.py`, `scripts/test/py/config_project.py`, `scripts/test/py/install_copy.py`
   Testes de aceitação AC-1..AC-8, vermelhos antes da implementação.
2. **factory** · dono: `engineer` · depende de 1 · arquivos: `scripts/runtimes/__init__.py` (novo), `scripts/runtimes/claude_code.py` (novo), `scripts/shipfloor_config.py`, `scripts/test/hygiene.test.sh`, código de install se a cópia não levar `scripts/runtimes/` (`scripts/shipfloor_core/cli.py` ou equivalente)
   Pacote `runtimes` (contrato: `NAMES`, `get`, `command`, `outcome`, `doctor`, `TRAILER`, `MODELS`, `LADDER`, `outcome_of`, `usage_limited`, sessões e custo do claude-code); `runtime_problems` em `problems()`/`machine_problems()`; consulta `machine runtimes [<factory.yml>]`; `MODELS`/`MODEL_LADDER` vindos do adaptador; `BUILTIN_FORBIDDEN` com `.codex/`, `.opencode/`, `.agents/`, `AGENTS.md`, `AGENTS.override.md`, `opencode.json(c)`; install sem `__pycache__`; `hygiene` aceita `legacy` em `scripts/runtimes/`. ACs: 1, 6, 7, 8 (parte de config).
3. **factory** · dono: `engineer` · depende de 2 · arquivos: `scripts/shipfloor_core/dispatch.py`, `scripts/shipfloor_core/cycle.py`, `scripts/shipfloor_core/deploy.py`, `scripts/shipfloor_core/report.py`
   `launch` monta argv/env/stdin por `runtimes.get(rt).command(...)` (idêntico ao de hoje para o claude-code); `runtime=` na linha `== start`, `outcome=` na linha `== end`; pausa por `runtimes.usage_limited` em dispatch e cycle; trailer `SHIPFLOOR_TRAILER` ou padrão. ACs: 2, 3, 8 (linha de comando e pausa).
4. **factory** · dono: `engineer` · depende de 2 · arquivos: `scripts/shipfloor_core/cli.py`
   `cmd_doctor`: `git`, `gh` e o `doctor()` de cada runtime em uso (config.yml + factory.yml de cada projeto registrado; nenhum → claude-code). AC-5.
5. **factory** · dono: `engineer` · depende de 2 · arquivos: `scripts/dashboard_cost.py`, `scripts/dashboard.py`
   Custo e sessões pelo contrato; cache `version: 2`, cache antigo descartado sem erro; `Factory.usage_limited` por `runtimes.usage_limited` (health herda). ACs: 3 (dashboard/health), 4, 8 (regra de pausa do dashboard).
6. **factory** · dono: `engineer` · depende de 2 · arquivos: `templates/factory-guard.yml`, `docs/configuration.md`, `README.md`
   Regex novo no template do factory-guard; seção **Runtime** na doc; `claude` como runtime padrão no README. `.github/workflows/factory-guard.yml` fica com o dono (caminho proibido).
