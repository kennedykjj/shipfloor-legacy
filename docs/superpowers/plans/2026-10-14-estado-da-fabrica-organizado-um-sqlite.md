# Plano — estado da fábrica em SQLite (etapa 1) — #262

Spec: `docs/superpowers/specs/2026-10-14-estado-da-fabrica-organizado-um-sqlite-design.md`. Uma camada (`factory`), agente `engineer`.

## Tarefas

1. **`state.py` (novo)** — `scripts/shipfloor_core/state.py`: `connect`, `migrate` (`MIGRATIONS`, `user_version`), `run_started`, `run_ended` (soma custo de `runs.jsonl`), `record_cycle`, `import_files`, `maintain` (import + retenção 90d/30d + backup diário, 7 cópias). Toda função pública captura `sqlite3.Error`/`OSError` e devolve `False`. Cobre AC-1, 2, 3, 5, 6.
2. **Escrita dupla** (depende de 1) — `scripts/shipfloor_core/dispatch.py` (`supervise`: `run_started` após `== start`; `run_ended` nos dois pontos de `== end`), `scripts/shipfloor_health.py` (`record_cycle` após anexar ao jsonl), `scripts/shipfloor_core/cycle.py` (`maintain` no `finally`, dentro de `try`). Cobre AC-4.
3. **Docs** (depende de 1) — `docs/contracts.md`: linhas `state.db` e `backups/state-<data>.db`; menção à manutenção diária.

## Testes
Aceitação (QA): `scripts/test/py/state_db.py` (novo, chamado por `py_suite` em `scripts/test/dispatch-cycle.test.sh`), `scripts/test/py/dispatch_launch.py`, `scripts/test/py/health_record.py`.
