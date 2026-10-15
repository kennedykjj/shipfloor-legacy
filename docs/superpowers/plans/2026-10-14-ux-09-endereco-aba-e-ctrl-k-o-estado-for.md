# Plano — #183 [UX-09] Endereço, aba e Ctrl K: o estado fora da página

**Spec:** `docs/superpowers/specs/2026-10-14-ux-09-endereco-aba-e-ctrl-k-o-estado-for-design.md`
**Base:** `main` já com #182 (área de trabalho, `selectCard`), #176 (dispatcher parado) e #184 (replay e `#@HHMM`, `fromAddress`, `setAddress`) integrados. O gancho `REPLAY` da spec é o replay real (`R`, `needle`, `backToLive`).

## Camadas

Uma camada só: `factory` (agente `engineer`).

## Tarefas

### T1 — Porta do dashboard e `Click` no push (factory, `engineer`)

Depende de: testes de aceitação do QA commitados.

1. `scripts/dashboard.py` — `main()` grava `<home>/dashboard.port` (uma linha, arquivo temporário + `os.replace`) depois do bind e o remove na saída limpa.
2. `scripts/shipfloor_notify.py` — `click_url(home, n)` lê a porta (1–65535, senão vazio); `send()` recebe `click` e acrescenta o cabeçalho `Click` (ntfy) ou o 4º argumento `<click>` (seam `SHIPFLOOR_NOTIFY_SEND`, `""` sem link); só as mensagens de espera e lembrete de um card passam o link.
3. `docs/contracts.md` — o novo argumento do seam e o arquivo `dashboard.port`.
4. Ajustar testes existentes que fixam a assinatura do seam, sem perder cobertura.

### T2 — Aba, endereço e paleta (factory, `engineer`)

Depende de: T1.

1. `scripts/dashboard.html`
   - Funções puras testáveis em node: `tabState(overview, project)`, `tabTitle(state, project)`, `parseHash(hash)` (`{card}`, `{at}` ou `null`), `hashOf(sel)`, `palette(query, cards, actions)` (até nove linhas).
   - Título e `favicon()` por estado (neutro, esperando, parado), redesenhados só quando o estado ou o tema muda; título escrito só quando o texto muda; "parado" usa o sinal do #176.
   - Endereço: `selectCard` empurra `#card/<n>`; `popstate`/`hashchange` restauram a seleção (somando-se ao `fromAddress` do replay, que segue dono de `#@HHMM`); hash de card inexistente ou malformado vira a visão padrão por `replaceState`, sem aviso.
   - Token: guardar `?t=` em `localStorage` (`shipfloor.token`) e usá-lo quando a URL não trouxer.
   - Botão do cabeçalho (`.btn ghost`, `kbd` oculto em `pointer: coarse`) e paleta (`role=dialog`, combobox/listbox, Ctrl K / Cmd K antes das teclas de uma letra, que ficam inertes com a paleta aberta; foco volta ao elemento anterior); as ações chamam os mesmos handlers dos botões (Próxima decisão, Pausar, Voltar ao vivo, Ver a esteira às HH:MM).
2. `scripts/lang/dashboard.{en,pt-BR,es,fr,de,it,ja,ko,ru,tr,zh-CN,zh-TW}.json` — as nove chaves `title.stopped` e `pal.*` da seção UX.
3. `docs/operation.md` — a aba, o endereço, a paleta, o link do push que só abre nesta máquina, `dashboard.port`.
4. `DESIGN.md` — regras de aba, endereço e paleta.
5. Testes existentes que quebrarem (contagem de chaves de idioma, atalhos, cabeçalho) — ajustar ao novo comportamento.
