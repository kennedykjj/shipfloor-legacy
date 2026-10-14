# Plano — #184 [UX-10] O dia em replay: o histórico do board e o diário preso à esteira

Spec: `docs/superpowers/specs/2026-10-14-ux-10-o-dia-em-replay-o-historico-do-boa-design.md`
Camada única: `factory` (agente `engineer`). As tarefas rodam em sequência, na ordem abaixo, no mesmo worktree.

Nota: a branch foi integrada com `origin/main` antes do plano, porque a spec depende da esteira (#181, entregue em #257), que não existia na base original da branch.

## T1 — Histórico do board (AC-1, AC-2)
- Camada: factory · Dono: engineer · Depende de: —
- Arquivos: novo `scripts/shipfloor_core/board_history.py` (`record(home, rows, now=None) -> bool`, `day(home, date) -> list`); `scripts/shipfloor_core/dispatch.py` (`read_board` chama `board_history.record(self.home, self.snapshot_rows())` depois do `os.replace`).
- Regras: uma linha por mudança em `<home>/logs/board-<YYYY-MM>.jsonl`, `cards` com o board inteiro, chaves string ordenadas; leitura vazia não escreve; `OSError` devolve False e não derruba o ciclo; `logs/` fica fora do `sweep_tmp`/`shipfloor clean` (sem mudança, só o teste fixa).

## T2 — API do dia (AC-3, lado servidor)
- Camada: factory · Dono: engineer · Depende de: T1
- Arquivos: `scripts/dashboard.py` — `GET /api/day/<project>` com os mesmos checks de token e projeto conhecido de `/api/history`; resposta `{"date", "now", "board", "marks", "error"?}`.
- Marcas: `ok`/`bad` a partir de `runs(p, day=hoje)` com `end` (`bad` = outcome `blocked`/`infra` no report pareado, ou saída não-zero); `decision` a partir de linhas consecutivas do histórico, card saindo de `Spec Review`/`Staged` para um destino em `OWNER_MOVES` (`approved-spec`, `approved-pr`, `requested-changes`, `moved:<coluna>`). O servidor manda chaves, nunca texto em inglês.

## T3 — Página: régua, marcas, replay e decisões desligadas (AC-3 página, AC-4, AC-5, AC-6, AC-7)
- Camada: factory · Dono: engineer · Depende de: T2
- Arquivos: `scripts/dashboard.html`; `scripts/lang/dashboard.*.json` (12: en e pt-BR com texto real, os outros 10 em inglês).
- Escopo: a régua dentro do painel da esteira (marcas com `title` e rótulo fora da tela, futuro hachurado, horas em mono); o playhead `role="slider"` com teclado e `#@HHMM` no endereço; o estado `R = {at, lines}` e a esteira desenhada da última linha com `t <= at`, pausada; os estados vazios/lendo/erro; a frase de status em modo replay com **Back to live** (e `Esc`); um único `deciding()` que todos os controles de decisão consultam; FLIP de 950ms, trocado por swap sob `prefers-reduced-motion`.

## T4 — Logbook e documentação (AC-8)
- Camada: factory · Dono: engineer · Depende de: T3
- Arquivos: `scripts/dashboard.html` (Feed vira **Logbook**/Diário na navegação e no título; o painel `#history` sai da visão Factory e entra no topo do Logbook, com título `Totals` + período; chave `shipfloor.history` e estado minimizado mantidos); `scripts/lang/dashboard.*.json` (`Logbook`, `Totals`); `docs/contracts.md` (arquivo `logs/board-<YYYY-MM>.jsonl` em "Files under ~/.shipfloor" e `/api/day` junto dos leitores do dashboard); `docs/operation.md` (um parágrafo sobre a régua e o replay).

## Testes de aceitação (QA, antes de T1)
- `scripts/test/py/board_history.py` — AC-1, AC-2 (rodado por `scripts/test/dispatch-cycle.test.sh`)
- `scripts/test/py/dashboard_day.py` — AC-3 servidor (rodado por `scripts/test/dashboard-views.test.sh`)
- `scripts/test/py/dashboard_replay.py` — AC-3 página, AC-4 a AC-8 (rodado por `scripts/test/dashboard-views.test.sh`)

Nenhum `*.test.sh` novo: `hygiene.test.sh` limita a suíte a 52 arquivos e a main já está em 52. O comportamento da página é testado executando o script da página em node sobre o DOM falso de `belt_page.py`, e não por grep do HTML.
