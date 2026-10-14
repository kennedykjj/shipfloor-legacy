# Gráficos "O dia da fábrica" e "Cards na esteira" no Diário do dashboard — spec

**Issue:** #261 · **Branch:** `feat/261-graficos-o-dia-da-fabrica-e-cards-na-est` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** para entender como a fábrica se comportou num dia (carga por etapa, pool cheio, paradas por limite do GitHub ou do Claude, o que entrou na `main`, por onde cada card passou), o dono hoje precisa ler o Feed run por run.
**Audience:** o dono da fábrica, numa olhada rápida no dashboard.
**Acceptance criteria**
- **AC-1** — Dado um health e logs de run de fixture com ciclos e execuções em mais de um dia, quando se chama `GET /api/day?project=<p>&date=<AAAA-MM-DD>` com o token, então vêm os ciclos, as execuções e os PRs mergeados daquele dia e só deles; sem o token, a resposta é recusada como nos outros endpoints.
- **AC-2** — Dado o Diário aberto, quando o dono não escolhe dia, então os dois gráficos mostram hoje, e a navegação leva aos dias anteriores e redesenha os dois.
- **AC-3** — Dado um dia com ciclos, quando "O dia da fábrica" é desenhado, então cada ciclo mostra a contagem em andamento por etapa empilhada em degraus, o tamanho do pool como linha tracejada, e um ciclo com `github_limited` ou `usage_limited` ganha uma faixa na cor de alerta.
- **AC-4** — Dado um dia com PRs mergeados na `main`, quando o gráfico é desenhado, então cada PR vira uma marca colorida pelo tipo do commit (`feat`, `fix`, `test`/`ci`, `docs`/`chore`), e passar o ponteiro numa marca mostra o número e o título; num ciclo, mostra a hora, a contagem por etapa e o pool.
- **AC-5** — Dado um dia com execuções, quando "Cards na esteira" é desenhado, então há uma linha por card e uma barra por execução colorida pela etapa; uma execução com exit diferente de 0 ganha contorno de alerta, uma ainda rodando vai até agora, e o tooltip mostra etapa, início, fim, duração, modelo e exit.
- **AC-6** — Dada a esteira, quando o dono escolhe uma etapa no filtro (Todas, Refinamento, Desenvolvimento, Validação, Deploy), então só as execuções dessa etapa ficam visíveis.
- **AC-7** — Dada uma barra de execução, quando o dono clica nela, então o card abre na aba Log, na execução clicada.
- **AC-8** — Dado o dashboard em tema claro e escuro, em largura estreita e com movimento reduzido, quando os gráficos são desenhados, então usam só os tokens do tema, a legenda segue o idioma do dashboard, as marcas de PR não se sobrepõem, nada anima e a página não carrega recurso externo.
**Out of scope:** gráficos de custo, intervalos de mais de um dia ou comparação entre dias, exportar dados, agregar vários projetos num gráfico, qualquer ação sobre cards a partir dos gráficos (só leitura e navegação ao Log), nova fonte de dados além do health, dos logs de run e da API REST do GitHub.
**Product fit:** serve o princípio 3 (números exatos e com fonte: tudo vem do health, dos logs de run e do `merged_at` do GitHub, nada estimado) e o 1 (o dashboard só lê, não guarda estado de card). A chamada à API REST do GitHub é leitura do mesmo GitHub que o dashboard já consulta, não contraria o "fica local". Depende da #184 (Diário), ainda aberta: sem ela, não há onde os gráficos morarem.
**Touches UI:** yes

## UX
_UX/UI Designer_

Nenhum componente novo: os gráficos reusam o SVG à mão de `.chart`, a `.key`, o grupo `.ftools` com `aria-pressed`, `STAGE_HUE` e o abridor de card do Feed.

- **Onde e fluxo (AC-2):** no Diário (#184; até lá, no History), depois dos gráficos que já existem e **só quando o período é um dia** (Hoje, um dia navegado com Anterior/Próximo ou um dia aberto no gráfico por dia). A navegação é o próprio controle de período, sem controle novo. Num período de vários dias, no lugar dos gráficos fica uma linha `.cap` `muted`. Para hoje, o redesenho segue o poll de 10s do History, e um dia passado é lido uma vez só.
- **O dia da fábrica (AC-3):** eixo x de 00h a 24h do dia, com marcas de hora a cada 3h (a cada 6h abaixo de 600px), 12px `faint`. A área empilhada em degraus (step-after) segue a ordem Refine, Develop, Validate, Deploy, preenchida com `STAGE_HUE` a 70% via `color-mix`. O pool é uma linha de 1px tracejada (4 2) em `muted`. Um ciclo parado ganha uma faixa da altura toda em `warn` a 14% atrás da área. Em hoje, uma linha fina `faint` marca agora. Altura de 140px (110px abaixo de 600px).
- **Marcas de PR (AC-4):** uma fileira de 14px sob o eixo, com um quadrado de 8px por PR no `merged_at`. Duas marcas a menos de 10px uma da outra se fundem numa marca com a contagem (Mono 12px), e o readout lista todos os PRs dela. A cor por tipo está em aberto (ver notes). A minha proposta é a forma carregar o tipo e a tinta ficar neutra: `feat` quadrado cheio `text`, `fix` losango `text`, `test`/`ci` quadrado vazado `muted`, `docs`/`chore` traço `faint`. Tudo isso entra na `.key`.
- **Cards na esteira (AC-5):** uma linha de 22px por card. A coluna de 52px à esquerda leva `#n` em Mono 13px 500 `soft`, e o eixo é o mesmo do gráfico de cima. Cada execução é uma barra de 10px, `rounded.bar`, na cor da etapa, com largura mínima de 3px. Exit diferente de 0 ganha um contorno `bad` de 1.5px. Uma execução que ainda roda vai até agora e termina com a borda direita tracejada, sem animação. A ordem dos cards é a do primeiro início. Com mais de 12 cards, a esteira rola dentro do painel e o eixo fica sticky.
- **Filtro (AC-6):** um `.ftools` (`role="group"`) sobre a esteira com `All`, `Refine`, `Develop`, `Validate`, `Deploy`. Os nomes de etapa ficam literais (regra do DESIGN), só `All` se traduz. Um card sem execução da etapa escolhida some, e o filtro dura até a página recarregar, sem ser guardado.
- **Tooltip = readout:** não há componente de tooltip, e `<title>` não funciona no toque nem no teclado. Então cada gráfico tem uma linha `.cap` `soft` sobre o SVG, `aria-live="polite"`, que mostra o item sob o ponteiro, focado ou tocado, e volta à dica quando nada está em foco. Cada item mantém também um `<title>` para leitor de tela.
- **Teclado e clique (AC-7):** cada gráfico é uma parada de tab (roving tabindex, como o gráfico por dia). No dia, Left e Right andam pelos ciclos e as marcas de PR têm uma parada própria. Na esteira, Left e Right andam pelas execuções do card, Up e Down mudam de card, e Home e End também valem. Enter ou o clique numa barra abre o card **maximizado no Log daquela execução**, como uma linha do Feed, e o foco volta à barra quando fecha. Uma marca de PR não abre nada, porque o readout já diz tudo. Alvo mínimo de 24px de altura por linha.
- **Estados:** carregando mostra `Reading the day…`, e no refresh o conteúdo antigo fica até o novo chegar. Um erro vira uma linha 12px `bad` e o último conteúdo válido fica. Sem ciclo no dia, o gráfico de cima é só o heading e a frase. Sem execução, a esteira é só o heading e a frase, sem o filtro. Se o GitHub falha ou está limitado, a fileira de PRs vira uma linha `muted` e o resto desenha normalmente.
- **Estreito e temas (AC-8):** os SVGs medem a largura do contêiner (ResizeObserver) e redesenham nela, sem `viewBox` esticado, para o texto continuar com 12px. Abaixo de 600px o readout quebra em duas linhas. Só tokens, nos 14 temas. Não há transição, então o movimento reduzido não precisa de fallback. Todo número usa tabular-nums.
- **Copy (en / pt-BR; chaves novas em `scripts/lang/dashboard.<code>.json`, e os outros idiomas caem no inglês):**
  - Headings: `The factory's day` / `O dia da fábrica`, `Cards on the belt` / `Cards na esteira`.
  - Key: `Pool` / `Pool`, `Stopped by a GitHub limit` / `Parada por limite do GitHub`, `Stopped by the Claude usage limit` / `Parada por limite de uso do Claude`.
  - Filtro: `All` / `Todas`, com o rótulo de grupo `Stage` / `Etapa`.
  - Readout do ciclo: `{time} · Refine {r} · Develop {d} · Validate {v} · Deploy {p} · pool {used} of {size}` / `… · pool {used} de {size}`, mais `· stopped: GitHub limit` / `· parada: limite do GitHub` e `· stopped: Claude usage limit` / `· parada: limite de uso do Claude`.
  - Readout de PR: `PR #{n} · merged {time} · {title}` / `PR #{n} · mergeado {time} · {title}`, com o título no `RAW`. Marca agrupada: `{n} PRs merged around {time}` / `{n} PRs mergeados por volta de {time}`.
  - Readout da execução: `{stage} · {start} – {end} · {dur} · {model} · exit {rc}`. Rodando: `{stage} · {start} – now · running {dur} · {model}` / `… – agora · rodando {dur} · …`.
  - Nome da barra: `#{n} {stage}, {start} to {end}, exit {rc}. Open the log` / `#{n} {stage}, {start} a {end}, exit {rc}. Abrir o log`.
  - Dicas: `Point at a cycle or a PR` / `Aponte para um ciclo ou um PR`, `Point at a run; click to open its log` / `Aponte para uma execução; clique para abrir o log`.
  - Estados: `Reading the day…` / `Lendo o dia…`, `Could not read the day: {error}` / `Não foi possível ler o dia: {error}`, `No dispatcher cycle on this day.` / `Nenhum ciclo do dispatcher neste dia.`, `No run on this day.` / `Nenhuma execução neste dia.`, `No {stage} run on this day.` / `Nenhuma execução de {stage} neste dia.`, `Merged PRs unavailable: {reason}` / `PRs mergeados indisponíveis: {reason}`, `Open a day to see the factory's day and the belt.` / `Abra um dia para ver o dia da fábrica e a esteira.`

## Architecture
_Tech Lead_

Camada única: `factory`. Sem migração, sem estado novo em disco.

**Contrato novo — `GET /api/day/<project>?date=<AAAA-MM-DD>`** (token no header como os outros; `date` omitido = hoje no relógio da máquina; data inválida ou futura → 400; projeto desconhecido → 404; sem token → 403):
- `date`, `now` (ISO), `present` (bool: é hoje).
- `cycles[]`: `ts`, `s`, `exit`, `pool {used, size}`, `running {refine, develop, validate, deploy}`, `github_limited`, `usage_limited` — linhas de `<home>/logs/health-<AAAA-MM>.jsonl` cujo `ts` cai no dia (data local); linha malformada é pulada.
- `runs[]`: `issue`, `title`, `stage`, `start`, `end`, `exit`, `model`, `log`, `running` — de `Factory.runs(p)` sobre os logs do dia e do dia anterior, mantidas as que se sobrepõem ao dia; `end` nulo e o card/etapa em `Factory.live(p)` → `running: true`.
- `prs[]`: `number`, `title`, `merged_at`, `kind` (`feat` | `fix` | `test` | `docs` | `other`, do prefixo convencional do título) e `prs_error` (nulo, ou o motivo quando o `gh` falha).

**`scripts/dashboard.py`**
- `Factory.day(p, day)`: monta a resposta acima; reusa `runs`, `live`, `titles`.
- `Factory.merged_prs(p, day)`: `gh api repos/<repo>/pulls?state=closed&base=<main>&sort=updated&direction=desc&per_page=100&page=<k>` (REST, fora da cota GraphQL), para quando a página termina antes do dia ou vem incompleta, no máximo 3 páginas; filtra `merged_at` pela data local. Cache em memória por `(p, day)`: 120 s para hoje, 1 h para dia passado; erro do `gh` não entra no cache.
- `Handler.do_GET`: rota `["api", "day", <p>]`, com validação da data no estilo de `history_period`.

**`scripts/dashboard.html`**
- Bloco do dia no History (no Diário depois da #184), abaixo dos gráficos atuais, só com período de um dia; lê `/api/day` junto com `loadHistory` (poll de 10 s só para hoje).
- `drawDay(svg, body)` e `drawBelt(svg, body, stage)`: SVG à mão, largura do contêiner via `ResizeObserver`, cores por tokens e `STAGE_HUE`, readout `aria-live`, roving tabindex; marcas de PR a menos de 10 px se fundem.
- Barra da esteira leva `data-open` + `data-log` e reusa o abridor do Feed (card maximizado no Log daquela execução). Texto vindo do GitHub entra só por `textContent`/escape.

**`scripts/lang/dashboard.en.json`, `scripts/lang/dashboard.pt-BR.json`**: as chaves da copy do `## UX`.

**Fixtures:** `scripts/test/demo_home.py` (linhas de health ao longo do dia, uma com `github_limited`, uma com `usage_limited`; execuções em duas etapas, uma com exit 1, uma rodando, uma de ontem que cruza a meia-noite) e `scripts/test/demo-gh` (responde `api repos/<repo>/pulls?...` com PRs de hoje e de ontem).

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/dashboard_views.py` |
| AC-2 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-3 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-4 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-5 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-6 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-7 | factory | `scripts/test/py/dashboard_browser.py` |
| AC-8 | factory | `scripts/test/py/dashboard_browser.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Rota `/api/day/<project>?date=` em vez de `/api/day?project=`: segue o padrão de caminho de `/api/history/<p>` e dos outros endpoints.
- Contagem por etapa e pool vêm do `stages`/`pool` globais do health (a máquina), como a issue lista: o pool é da máquina, e empilhar contagens de um projeto contra ele enganaria.
- Os gráficos entram no History atual enquanto a #184 não sai, e mudam com ele para o Diário: assim o card não fica preso à #184.
- Navegação entre dias é o controle de período existente; os gráficos só aparecem com período de um dia (sem controle novo).
- Execução que cruza a meia-noite aparece nos dois dias, cortada na borda; por isso o endpoint lê também os logs do dia anterior.
- Execução sem `== end` só conta como rodando se o card/etapa está em `live`; senão, `running: false` e `end` nulo (desenhada até o fim do dia ou agora).
- PRs: REST `pulls` paginado até 3 páginas com cache de 120 s (hoje) e 1 h (passado); erro do GitHub vira `prs_error` e o resto do dia desenha.
- Tipo do PR pelo prefixo convencional do título; tipo fora de `feat`/`fix`/`test`/`ci`/`docs`/`chore` vira `other`.
- Tooltip vira readout `aria-live` sobre cada gráfico (UX): `<title>` não funciona no toque nem no teclado.
- Filtro com nomes de etapa literais (Refine, Develop, Validate, Deploy) e só `All` traduzido, como manda o `DESIGN.md`, divergindo dos nomes em português da issue.
- Copy nova só em en e pt-BR; os outros catálogos caem no inglês, como nas specs anteriores.
- Testes de navegador em `dashboard_browser.py` com o demo (`demo_home.py` + `demo-gh`), que é a fixture que eles já usam.
- Título de PR é texto de terceiro: entra só por escape/`textContent`, nunca como HTML.

## Open questions
- **Marcas de PR:** forma por tipo com tinta neutra (recommended) ou cor por tipo como na issue — a cor contraria o `DESIGN.md` (sem codificar por cor) e se confunde com as cores das etapas no mesmo gráfico.
