# Estado da fábrica organizado: um SQLite por máquina para estado e histórico, arquivos só para artefatos — spec

**Issue:** #262 · **Branch:** `feat/262-estado-da-fabrica-organizado-um-sqlite` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead
**Weight:** heavy

## Product
_Product Owner_

**Problem:** O histórico de execuções e de ciclos vive em texto e JSONL sem esquema (linhas `== start`/`== end` dos logs de run, `health-*.jsonl`), relido a cada consulta, sem retenção nem backup. Esta é a etapa 1 da migração: criar o banco `~/.shipfloor/state.db` com `runs` e `cycles`, importar o que existe, escrever nos dois lugares e dar ao banco retenção e backup.
**Audience:** O dono da fábrica, que roda o Shipfloor na própria máquina (e os desenvolvedores que instalam o plugin, que recebem o mesmo banco).
**Acceptance criteria**
- **AC-1** — Dado uma máquina sem `~/.shipfloor/state.db`, quando a fábrica roda um ciclo, então o arquivo é criado em modo WAL com `PRAGMA user_version` igual à última migração e as tabelas `runs` e `cycles`; num banco de versão anterior, as migrações pendentes são aplicadas sem perder linhas.
- **AC-2** — Dado logs de run com linhas `== start`/`== end` e arquivos `health-*.jsonl` existentes, quando a importação roda, então cada execução vira uma linha em `runs` (projeto, card, etapa, início, fim, exit, modelo, peso, custo quando houver, caminho do log) e cada registro de health uma linha em `cycles`.
- **AC-3** — Dado uma importação já feita, quando ela roda de novo, então a contagem de linhas de `runs` e `cycles` não muda (sem duplicatas); uma execução que tinha só `== start` e depois ganhou `== end` é atualizada, não duplicada.
- **AC-4** — Dado o banco criado, quando o supervisor inicia e termina uma execução e o ciclo grava o health, então as linhas aparecem em `runs`/`cycles` e os logs e o `health-*.jsonl` continuam sendo escritos como hoje (escrita dupla); se o banco falhar (bloqueado, corrompido), o arquivo ainda é escrito e a execução não falha.
- **AC-5** — Dado linhas de `runs`/`cycles` com mais de 90 dias e logs de execuções terminadas há mais de 30 dias, quando o ciclo roda a retenção, então essas linhas e esses logs saem, e logs de execuções em andamento ou terminadas há 30 dias ou menos ficam.
- **AC-6** — Dado que não há backup do dia em `~/.shipfloor/backups/`, quando o ciclo roda, então um `.backup` do SQLite é gravado lá (uma cópia por dia, não a cada ciclo) e só as 7 cópias mais recentes ficam.
**Out of scope:** Etapa 2 (card de seguimento): dashboard, health, notify e `doctor` lendo do banco e o `health-*.jsonl` deixando de ser escrito. Etapa 3 (card de seguimento): `board_snapshots`/`board_history`, `deps`, `accepted`, `notify`, `limits` (marcadores) migrados e os arquivos antigos removidos. Comentário na issue a cada `shipfloor accept` (card próprio, já decidido pelo dono). Locks (continuam com `mkdir`), retenção de `tmp/`, `reviews/`, `gate-passes/` e worktrees, estado entre máquinas, mudar o board do GitHub como fonte da verdade, qualquer mudança visual.
**Product fit:** Serve o princípio 3 (números exatos e com fonte): o histórico de execuções passa a ter um esquema único e consultável, base do Feed, da esteira e da #261. Respeita o princípio 1: o banco guarda histórico de execuções e ciclos, não estado de card; o board segue sendo a fonte da verdade. Coerente com o contexto operacional (tudo sob `~/.shipfloor`) e com a stack (só `sqlite3` da biblioteca padrão). A remoção de logs com mais de 30 dias apaga artefatos que hoje só o `shipfloor clean` manual tira; é decisão explícita do dono na issue.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Uma camada só (`factory`). Nenhum endpoint, evento ou tela muda; os arquivos de hoje continuam escritos e lidos como estão.

**Módulo novo `scripts/shipfloor_core/state.py`** (stdlib `sqlite3`), único dono do banco:
- `connect(home=None)` → conexão em `<shipfloor home>/state.db` (`project.shipfloor_home()` por padrão), `journal_mode=WAL`, `busy_timeout=5000`, e aplica `migrate()`.
- `migrate(conn)`: lista `MIGRATIONS` no pacote; aplica, numa transação cada, as de índice maior que `PRAGMA user_version` e grava o novo `user_version`. Versão 1 cria:
  - `runs(id INTEGER PK, project TEXT, card INTEGER, stage TEXT, pid INTEGER, started TEXT, started_s INTEGER, ended TEXT, ended_s INTEGER, exit INTEGER, outcome TEXT, model TEXT, weight TEXT, runtime TEXT, cost_usd REAL, log TEXT, UNIQUE(log, started))`, índices em `started_s` e `(project, card)`.
  - `cycles(id INTEGER PK, ts TEXT UNIQUE, ts_s INTEGER, seconds INTEGER, exit INTEGER, overlap INTEGER, data TEXT)`: `data` é a linha de health inteira em JSON; índice em `ts_s`.
- `run_started(project, card, stage, pid, started, model, weight, runtime, log)` e `run_ended(log, started, exit, outcome, ended)`: upsert pela chave `(log, started)`. `run_ended` soma `cost_usd` das linhas de `<project home>/logs/runs.jsonl` com o mesmo `pid` e `card` e `start` ≥ `started` (o deploy chama o agente até 3 vezes numa execução).
- `record_cycle(line)`: `INSERT OR IGNORE` por `ts`.
- `import_files(home)`: lê `projects/*/logs/*.log` (pares `== start` / `== end`, mesmo formato que `demo.py` e `dispatch._end_line` escrevem) e `logs/health-*.jsonl`; passa pelas mesmas funções acima, então rodar de novo não duplica e uma execução que ganhou `== end` é atualizada (AC-2, AC-3). Linhas truncadas são puladas, como `shipfloor_health.alerts` já faz.
- `maintain(home, now)`: uma vez por dia (marcada pela existência do backup do dia): `import_files`, retenção e backup. Retenção: apaga `runs` com `ended_s` e `cycles` com `ts_s` de mais de 90 dias; apaga cada `.log` (e seu `.events.jsonl`) cujas execuções terminaram todas há mais de 30 dias e sem nenhuma aberta (`ended` nulo). Backup: `Connection.backup()` (a mesma API online do `.backup` do CLI, sem depender do binário `sqlite3`) para `~/.shipfloor/backups/state-<YYYY-MM-DD>.db`, depois mantém só os 7 mais novos por nome.
- Toda função pública captura `sqlite3.Error` e `OSError`, escreve uma linha no stderr e devolve `False`: o banco nunca falha quem o chama (AC-4).

**Pontos de escrita (escrita dupla):**
- `scripts/shipfloor_core/dispatch.py` `supervise`: logo após o `_append` do `== start`, `state.run_started(...)` (projeto = nome da pasta de `spec["home"]`); nos dois lugares que gravam `== end` (o ramo "no control" e `_work`, onde `_end_line` é anexado), `state.run_ended(...)` com o mesmo `started`.
- `scripts/shipfloor_health.py` `main` (`record`): depois de anexar a linha ao `health-<YYYY-MM>.jsonl`, `state.record_cycle(line)`.
- `scripts/shipfloor_core/cycle.py` `run_cycle`: no `finally`, depois de `_record`, `state.maintain(home, now)` dentro de `try` (nunca muda o exit do ciclo).

**Docs:** `docs/contracts.md`, seção "Files under ~/.shipfloor": linhas para `state.db` (escrito por `dispatch.py`, `shipfloor_health.py`, `cycle.py`; lido por ninguém ainda) e `backups/state-<data>.db`; a seção `shipfloor-dispatch.sh` cita a manutenção diária.

**Arquivos:** `scripts/shipfloor_core/state.py` (novo), `scripts/shipfloor_core/dispatch.py`, `scripts/shipfloor_core/cycle.py`, `scripts/shipfloor_health.py`, `docs/contracts.md`, `scripts/test/py/state_db.py` (novo), `scripts/test/dispatch-cycle.test.sh`, `scripts/test/py/dispatch_launch.py`, `scripts/test/py/health_record.py`.

**Migração:** só expand. O banco é novo e nenhum leitor depende dele; os arquivos não mudam. Apagar `state.db` volta ao estado de hoje.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/state_db.py` |
| AC-2 | factory | `scripts/test/py/state_db.py` |
| AC-3 | factory | `scripts/test/py/state_db.py` |
| AC-4 | factory | `scripts/test/py/dispatch_launch.py` |
| AC-5 | factory | `scripts/test/py/state_db.py` |
| AC-6 | factory | `scripts/test/py/state_db.py` |

## Security
_Cybersec_ — n/a

## Rollback
Reverter o commit e apagar `~/.shipfloor/state.db*` e `~/.shipfloor/backups/`; nada lê o banco nesta etapa. Os logs de run já apagados pela retenção não voltam (só os de mais de 30 dias, decisão do dono).

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Este card é só a etapa 1 da issue (banco, `runs`, `cycles`, importação, escrita dupla, retenção e backup); etapas 2 e 3 viram cards de seguimento, como a própria issue e o dono pedem.
- Chave de uma execução = `(caminho do log, início)`: um mesmo `.log` do dia recebe várias execuções, e só esse par é igual na importação e na escrita ao vivo.
- Custo vem do `runs.jsonl` existente (somado por `pid`/card/início), não de um campo novo na telemetria: um caminho só para a importação e para a escrita ao vivo.
- Backup por `sqlite3.Connection.backup()` em vez do binário `sqlite3`: mesmo resultado do `.backup`, sem exigir o CLI instalado (Windows/macOS).
- Importação, retenção e backup rodam uma vez por dia dentro do ciclo, não a cada ciclo: reler todos os logs a cada 5 min é o custo que a issue quer tirar.
- A importação diária também recupera execuções que a escrita dupla perdeu (banco travado), então nenhuma falha do banco precisa de nova tentativa no caminho da execução.
- Retenção dos logs apaga também o `.events.jsonl` ao lado: é artefato da mesma execução.
- `health-*.jsonl` e `runs.jsonl` não entram na retenção nesta etapa: seguem como fonte dos leitores até a etapa 2.
- Suíte nova `scripts/test/py/state_db.py` (chamada por `py_suite` no `dispatch-cycle.test.sh`, junto do `board_history`): nenhuma suíte cobre o módulo novo; a escrita dupla dos ciclos fica em `scripts/test/py/health_record.py`.
- Peso `heavy`: 9 arquivos e mexe no supervisor de toda execução e apaga artefatos.

## Open questions
- none
