# Plano — gráficos "O dia da fábrica" e "Cards na esteira" (#261)

Spec: `docs/superpowers/specs/2026-10-14-graficos-o-dia-da-fabrica-e-cards-na-est-design.md`. Camada única: `factory` (agente `engineer`).
As tarefas compartilham o worktree e rodam em ordem.

## Tarefas

1. **Endpoint `GET /api/factory-day/<p>?date=`** (`factory`, `engineer`)
   - Arquivos: `scripts/dashboard.py`.
   - `Factory.factory_day(p, day)` e `Factory.merged_prs(p, day)` (REST `pulls`, até 3 páginas, cache 120 s hoje / 1 h passado, erro fora do cache), rota em `Handler.do_GET` com validação de data (400 inválida/futura, 404 projeto, 403 sem token).
   - Depende de: nada.

2. **Fixtures do demo** (`factory`, `engineer`)
   - Arquivos: `scripts/test/demo_home.py`, `scripts/test/demo-gh`.
   - Health ao longo do dia (um ciclo `github_limited`, um `usage_limited`), execuções em duas etapas (uma exit 1, uma rodando, uma de ontem cruzando a meia-noite), `demo-gh` responde `api repos/<repo>/pulls?...` com PRs de hoje e de ontem.
   - Depende de: 1 (contrato). Sem mexer nos testes de aceite do QA.

3. **Gráficos no Logbook + copy** (`factory`, `engineer`)
   - Arquivos: `scripts/dashboard.html`, `scripts/lang/dashboard.en.json`, `scripts/lang/dashboard.pt-BR.json`.
   - `drawDay`, `drawBelt`, readout `aria-live`, roving tabindex, filtro `.ftools`, marcas de PR fundidas a <10 px, abertura do card no Log da execução, estados, `ResizeObserver`, só tokens do tema.
   - Depende de: 1 e 2.
