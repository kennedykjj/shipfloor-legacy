# Plano — #182 [UX-08] A área de trabalho: uma coisa por vez, decidir sem trocar de tela

**Spec:** `docs/superpowers/specs/2026-10-14-ux-08-a-area-de-trabalho-uma-coisa-por-v-design.md`
**Base:** rebaseado em `main` com #179 (`briefHTML`) e #181 (a esteira) já integrados.

## Camadas

Uma camada só: `factory` (agente `engineer`).

## Tarefas

Uma tarefa única, porque o gate `build` roda os testes dos arquivos mudados (inclusive os testes de aceitação do QA em `dashboard-work-area`, `dashboard-work-keys`, `dashboard-quick` e `design-doc`): dividir em tarefas deixaria o build vermelho entre elas sem ganho.

### T1 — A área de trabalho (factory, `engineer`)

Depende de: testes de aceitação do QA commitados.

1. `scripts/dashboard.html`
   - Painel `#work` (rótulo de região "A área de trabalho") logo abaixo da esteira, no lugar de `#cols` (lista "Yours" e grade "In progress"); remover `renderYours` e os tiles de in progress.
   - Funções puras, sem DOM, testáveis em node: `decisionQueue(cards, skipped)`, `workMode(state)` → `decide | run | card | calm`, `nextGates(cards)`.
   - `S.work = {key, skipped: Set}` só em memória da página; clicar/Enter/Espaço numa ficha da esteira (#181) define `S.work.key` em vez de abrir o drawer; clicar de novo ou `Esc` limpa.
   - `renderWork()` → `renderDecide` (cabeçalho, `1 of N decisions`, próximo, título, `briefHTML` ou iframe da revisão, painel fixo Your decision com Approve / Request changes / Skip for now, select de peso no Spec Review, confirmação de aprovar com dúvida, sugestões, nota, Send), `renderRun` (passos, últimas cinco chamadas de ferramenta, campo para falar com a run, passo, relógio, custo est., Log, GitHub), `renderCardMode` (estado em palavras, custo est., Unblock and retry quando bloqueado), `renderCalm` (três colunas).
   - Troca com transição (260 ms saída, 400 ms entrada) e `prefers-reduced-motion: reduce` sem transição.
   - Um handler `keydown` para `A`/`R`/`N`/`Enter`/`Esc`, ignorado em `input`, `textarea`, `select`, `[contenteditable]`, iframe ou com a visão maximizada aberta; saem as teclas da lista Yours e o rodapé vira `A approve · R request changes · N skip`.
   - Reusar o hold de 5 s, o Undo e o envio por `pagehide` do quick approve (#50) dentro de Your decision; depois da janela, entra o próximo cartão e o foco vai para o título; depois do último, Calm.
   - O drawer lateral sai; Sessions, Log, Gates e Review ficam na visão maximizada, aberta pelos links de cada modo.
2. `scripts/dashboard.py` — só se #181 não trouxe: `shipped` por projeto (`{issue, title, pr, at, cost}` dos cartões que chegaram a Done hoje).
3. `scripts/lang/dashboard.*.json` (12) — chaves `work.*` (en e pt-BR conforme a seção UX; as outras 10 em inglês); apagar as chaves da lista Yours, dos tiles e da decisão do drawer.
4. `DESIGN.md` — seção "The Work Area" no lugar de Your, In Progress, Tooltip Drawer e How a Card Opens; Layout e Keyboard and Live Updates acompanham.
5. Testes existentes que citam Yours, tiles ou o drawer e não são testes de aceitação do QA: `dashboard`, `dashboard-first-screen`, `dashboard-weight`, `dashboard-names`, `dashboard-narrow`, `dashboard-short`, `dashboard-page`, `dashboard-touch`, `dashboard-targets` (`scripts/test/*.test.sh`) e os testes de navegador do dashboard que quebrarem — ajustar ao novo comportamento, sem perder cobertura das ações.

Arquivos: `scripts/dashboard.html`, `scripts/dashboard.py`, `scripts/lang/dashboard.*.json`, `DESIGN.md`, `scripts/test/dashboard*.test.sh` (exceto os do QA), `scripts/test/py/*` relacionados ao dashboard, se houver.

## Testes de aceitação (QA)

| AC | Arquivo |
|---|---|
| AC-1, AC-4, AC-5, AC-6, AC-7 | `scripts/test/dashboard-work-area.test.sh` (novo) |
| AC-2 | `scripts/test/dashboard-work-keys.test.sh` (novo) |
| AC-3 | `scripts/test/dashboard-quick.test.sh` (existente) |
| AC-8 | `scripts/test/design-doc.test.sh` (existente) |

## Riscos

- `dashboard.html` é grande (≈2.800 linhas) e o drawer é usado por vários testes: remover sem perder Sessions/Log/Gates/Review/peso/unblock (AC-7).
- Teclas globais não podem disparar dentro de campos de texto nem do iframe.
