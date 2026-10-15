# Plano — #150 Runtimes 2/4: runtime codex (Codex CLI)

Spec: `docs/superpowers/specs/2026-10-14-runtimes-2-4-runtime-codex-codex-cli-design.md`. Camada única: `factory` (agente `engineer`).

**Ajuste ao spec:** o contrato de #149 que chegou à `main` é Python (`scripts/runtimes/__init__.py`, um módulo por runtime com `NAME`, `BINARY`, `MODELS`, `LADDER`, `TRAILER`, `command(run)`, `outcome(rc, block)`, `doctor()` e os leitores `data_dir`, `session_files`, `stamp`, `parse`, `parse_ts`, `events`, `text_of`, `doing`, `COMMAND`). Não há `rt_run`/`rt_outcome` em shell: o que o spec chama de `codex.sh` vira `command`/`outcome`/`doctor` de `scripts/runtimes/codex.py`. O dispatcher (`shipfloor_core/dispatch.py` `launch`/`_end_line`) já chama o contrato; o binário vem de `rt.BINARY` (o Codex lê `FACTORY_CODEX` para os testes apontarem um `codex` falso).

## Tarefas (em ordem; dividem o worktree)

### T1 — Config: `runtime.models` e `runtime.ladder` (factory · engineer)
- `scripts/shipfloor_config.py`: `runtime_problems` aceita `models` (`stages`: modelo ou mapa por peso, `refine` um modelo só, `agents`: nome → modelo) e `ladder` (lista de nomes); outra chave continua inválida. Nomes de modelo livres (texto não vazio).
- `stage-models` devolve, para a etapa cujo runtime não é `claude-code`, os modelos de `runtime.models` (vazio = padrão do runtime); `model-up` / `next_model` sobe pela `runtime.ladder` do runtime da etapa (sem escada, não sobe). `models.stages` só vale para `claude-code`.
- Aviso no `doctor` quando `models.stages.<etapa>` está definido e o runtime da etapa não é `claude-code`.
- Arquivos: `scripts/shipfloor_config.py`, `scripts/shipfloor_core/dispatch.py` (leitura dos modelos/escada por runtime), `scripts/shipfloor_core/cli.py` (aviso).
- ACs: AC-3, AC-8.

### T2 — Adaptador Codex e gerador do `CODEX_HOME` (factory · engineer) — depende de T1
- `scripts/runtimes/__init__.py`: `NAMES = ("claude-code", "codex")`.
- `scripts/runtimes/codex.py`: `NAME="codex"`, `BINARY` (`FACTORY_CODEX` ou `codex`), `MODELS=()`, `LADDER=()`, `TRAILER="Co-Authored-By: Codex <noreply@openai.com>"`; `command(run)` → `exec -s workspace-write -C <control> [-m <model>] --add-dir <cada write> --skip-git-repo-check --json -o <log>.last -`, env `CODEX_HOME=<home da fábrica>`, stdin = `<CODEX_HOME>/sf/<etapa>.md` + `Card: #<n>`; `outcome(rc, block)` com a regex de limite do spec sobre o bloco e o `.last` (`’` cru ou escapado `’`); `doctor()` (binário, versão mínima, `codex login status` com o `CODEX_HOME` ou `CODEX_API_KEY`, `config.toml` e `agents/` gerados); leitores `data_dir` (`SHIPFLOOR_CODEX_HOME` ou `~/.shipfloor/runtimes/codex`), `session_files` (rollouts com `session_meta.cwd` = `control`, subagentes por `parent_thread_id`, `.jsonl.zst` só com descompressor), `stamp`, `parse` (marcador `<!-- sf:stage=<etapa> -->`, `Card: #<n>`, tokens de `token_count`, modelo de `turn_context`, `input = input − cached`, `cache_read = cached`), `events` (falas, comandos, mensagem do dono → `owner`).
- `scripts/runtimes/codex_gen.py` + `scripts/shipfloor_core/cli.py` `cmd_install`: gera `config.toml`, `agents/<nome>.toml` (modelo de `runtime.models.agents`), `sf/<etapa>.md` (frontmatter fora, marcador de etapa, blocos `rt:codex` expandidos e os do Claude removidos); idempotente; não toca em `auth.json`.
- Mensagens do dono: protocolo do inbox no começo de cada passo (prompt gerado lê `<SHIPFLOOR_RUN_LOCK>/inbox` a partir de `inbox.lead`); `scripts/inbox_hook.py` ganha o modo `--codex` só se o hook do Codex devolver contexto.
- `cycle.py`/`dispatch.py`/`shipfloor_notify.py` + `scripts/lang/pt-BR.sed` + `scripts/lang/notify.pt-BR.json`: a mensagem de limite nomeia o runtime (`Claude`/`Codex`); com `claude-code` igual à de hoje.
- Um `codex` falso para os testes em `scripts/test/` (grava argv/stdin, escreve um rollout).
- ACs: AC-1, AC-2, AC-4, AC-5, AC-6, AC-8.

### T3 — Marcadores de runtime nas skills e agentes (factory · engineer) — depende de T2
- `skills/{refine,develop,validate,deploy}/SKILL.md`, `agents/*.md`: blocos `<!-- rt:codex -->…<!-- /rt -->` em comentário HTML (o texto que o Claude Code lê não muda), expandidos por `codex_gen.py`.
- ACs: AC-1, AC-5.

### T4 — Custo e dashboard (factory · engineer) — depende de T2
- `templates/prices.yml`: modelos da OpenAI conhecidos.
- `scripts/dashboard.py` (`priced` em `models()`), `scripts/dashboard_cost.py`, `scripts/dashboard.html`: preço pelo nome completo; modelo sem preço → `money(null)` = `$ ?`, nunca zero (também no total misto); `cap()` só para os aliases do Claude; campo de texto livre (`.cin`) no Settings para etapa de runtime sem `MODELS`; `models.def.codex` nos 12 `scripts/lang/dashboard.*.json`.
- ACs: AC-6, AC-7.

### T5 — Docs (factory · engineer) — depende de T1–T4
- `docs/configuration.md`, `docs/install.md`, `docs/operation.md`, `docs/how-it-works.md`, `docs/contracts.md`, `PRODUCT.md` (Positioning: custo "dos transcripts de cada runtime").
- ACs: —.

## Testes de aceitação (QA, antes de T1)
Nas suítes existentes do test plan: `scripts/test/py/dispatch_cycle.py` (AC-1, AC-4), `scripts/test/py/dispatch_launch.py` (AC-2, AC-3), `scripts/test/py/dashboard_cards.py` (AC-5), `scripts/test/py/dispatch_cost.py` (AC-6, AC-7), `scripts/test/py/cli_doctor.py` (AC-8).
