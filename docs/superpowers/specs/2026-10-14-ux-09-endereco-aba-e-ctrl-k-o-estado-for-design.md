# #30/37 [UX-09] Address, tab and Ctrl K: the state outside the page — spec

**Issue:** #183 · **Branch:** `feat/183-ux-09-endereco-aba-e-ctrl-k-o-estado-for` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The owner keeps the dashboard pinned in a tab, but the tab says nothing: they must open the page to know whether a decision waits or the factory stopped. Nothing in the dashboard has an address, so the ntfy push cannot lead to its card and Back leaves the page instead of undoing the last selection.
**Audience:** The factory's owner, who runs Shipfloor on their own machine and checks the dashboard quickly.
**Acceptance criteria**
- **AC-1** — Given N decisions wait for the owner (N > 0), when the next read cycle (2 s) completes, even with the tab in the background, then the tab title reads `(N) Shipfloor · <PROJECT>` and the 14px favicon is drawn in the accent color; with nothing waiting the title is `Shipfloor · <PROJECT>` and the favicon is neutral.
- **AC-2** — Given the dispatcher is stopped (#176), when the next read cycle completes, then the title reads `Shipfloor · <PROJECT> · <title.stopped>` (`stopped` in English, `parado` in pt-BR) and the favicon is drawn in the `bad` color.
- **AC-3** — Given the owner selects card #120 in the work area, when the selection happens, then the URL hash becomes `#card/120`, and pressing Back restores the previous selection instead of leaving the page.
- **AC-4** — Given a URL with `#card/120` is opened directly, when the page loads, then card #120 is selected; a hash for a card that does not exist, a malformed hash, or a replay hash (`#@0940`) while the page has no replay yet, shows the default view with no error.
- **AC-5** — Given ntfy is configured and the dashboard port is known, when a push is sent for a card waiting for the owner, then it carries a `Click` header `http://127.0.0.1:<port>/#card/<n>`; when the port is unknown, the push is sent without `Click`, exactly as today.
- **AC-6** — Given the page is open, when the owner presses Ctrl K / Cmd K or clicks the header button, then a palette opens with one field and at most nine results: the actions the page offers at that moment (Next decision, Pause the factory; Back to live and See the line at <time> once the replay of #184 exists), and cards matched by `120`, `#120` or a word of the title, each showing its column.
- **AC-7** — Given the palette is open, when the owner moves with the arrow keys and presses Enter on a result, then it does exactly what the matching page button or card click does; when they press Esc, the palette closes and focus returns to the element focused before it opened.
- **AC-8** — Given the operation docs, when the owner reads `docs/operation.md`, then it states that the push link only works when read on the same machine, since the dashboard stays on 127.0.0.1.
**Out of scope:** Remote or LAN access to the dashboard; any new action in the palette that the page does not already offer; unread counts or sounds; browser notifications; addresses for review pages or logs beyond the card and replay time; changes to the work-area selection itself (#182, UX-08); the replay and its `#@HHMM` address (#184, UX-10, which comes after this card and plugs into the hooks below).
**Product fit:** Serves principle 4 (the owner acts only where the factory waits): the tab and push point straight at what waits for the owner. The waiting count and stopped state come from the dispatcher's snapshot, and the hash holds only a view, never card state (principle 1). The `Click` link adds only a 127.0.0.1 URL with the card number to the push, already part of what it carries, so the "dashboard stays local" constraint holds. Depends on #182 being merged first.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Header button:** a `.btn ghost` at the right end of `<header>`, after `.stats`: the label `pal.open` followed by `<kbd>Ctrl K</kbd>` (`⌘ K` on macOS). The `kbd` hides under `pointer: coarse`, the same as `.iopt kbd`. It opens the same palette as the shortcut.
- **Palette layout:** a `role="dialog"` box over the existing `#dim` scrim, top-centred at 12vh, `min(560px, 100vw − 32px)` wide, `--panel-hi`, a 1px `--edge-hi` border, 14px radius, `--shadow`. Inside: one text field (15px, placeholder `pal.field`) above a list of up to 9 rows. An action row shows its label alone. A card row shows `#120` in `.g` mono `--sand` when it waits for the owner and `--text` otherwise, then the title (one line, ellipsis), then the column name in 12px `--muted` at the right. The active row has a `--raise`/`--panel` fill and a 2px `--text` left edge. Actions come first, then cards by board order.
- **What it finds:** with the field empty, the available actions and then the waiting cards, oldest first. `120` and `#120` put that card first. Other words match card titles and action labels, case- and accent-insensitive. Typing a time (`9:40`, `09:40` or `0940`) adds `pal.at` with that time. An action shows only when its page button would be enabled: `pal.next` while a decision waits, `pal.live` during a replay, `pal.at` once the replay exists (#UX-10), `pal.pause` while the dispatcher runs. No match shows one `pal.none` row in `--muted` that cannot be selected.
- **Keyboard and focus:** Ctrl K / Cmd K toggles the palette from anywhere, even while typing in a field. The page's single-letter keys (`A`, `R`, `N`, `1–9`) are inert while it is open. Opening it focuses the field with the first row active. ↑/↓ move and wrap, Home/End jump to the ends, and Enter runs the active row. Running a row is the same handler as the matching button or the token click, and it closes the palette. Esc, a click on the scrim or Ctrl K again close it without acting. Tab stays inside it. On close, focus returns to the element that was focused before it opened (`document.body` if that element is gone). If an action leaves focus somewhere new, such as a card selected in the work area, focus goes there instead.
- **States:** before the first read, the field works and the list shows the existing `msg.reading` in `--muted`. If an action fails, the palette closes and the page's own `.notice` reports the failure, as it does for the button. It shows no error of its own.
- **Small screen (< 600px):** the box is full width with a 16px gap at the top, the rows have a 44px minimum height, and the list scrolls inside the box (`max-height: 60vh`). The column name moves under the title in 12px.
- **Favicon:** keep today's `favicon()` tile (the brand mark on a `--ground` square, 14px of 16px). Only its colours carry the state. *Neutral:* the route is drawn in `--muted` and the card in `--text`, so the accent keeps one meaning. *Waiting:* the tile is filled with `--sand` and the route and card are drawn in `--ground`. *Stopped:* the same, with `--bad`. Stopped outranks waiting. Colours are read from the theme as they are today. The favicon redraws only when the state or theme changes, and it ignores replay because it always shows live state.
- **Title:** `Shipfloor · <project>` uses the same project name that `#scope` shows. While N decisions wait it becomes `(N) Shipfloor · <project>`. When the dispatcher stopped it becomes `Shipfloor · <project> · {title.stopped}`, or `(N) Shipfloor · <project> · {title.stopped}` when decisions also wait. A replay does not change it. The title is updated on every read cycle and only written when its text changes.
- **Address:** selecting a card pushes `#card/<n>`, and Back restores the previous selection and focus. A hash for a missing card, or a malformed hash, is replaced silently (`replaceState`) by the default view, with no notice. Moving through the palette rows does not push anything. Only the action it runs does.
- **Reduced motion:** the palette has no animation of its own. The `#dim` fade is already removed under `prefers-reduced-motion`. The favicon and title change without any blink.
- **Accessibility:** the field is `role="combobox"` with `aria-expanded`, `aria-controls` pointing to a `role="listbox"`, and `aria-activedescendant` on the active `role="option"`. The dialog carries `aria-modal="true"` and `aria-label` = `pal.open`. A visually hidden polite live region announces `pal.count` after typing stops for 250ms. The header button has `aria-keyshortcuts="Control+K Meta+K"`. The waiting and stopped states are already spoken by the status line, so the favicon needs no text.
- **Copy (new keys, every catalog):**

| key | en | pt-BR | es | fr | de | it | ja | ko | ru | tr | zh-CN | zh-TW |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `title.stopped` | stopped | parado | detenido | arrêté | gestoppt | fermo | 停止中 | 중지됨 | остановлен | durdu | 已停止 | 已停止 |
| `pal.open` | Commands | Comandos | Comandos | Commandes | Befehle | Comandi | コマンド | 명령 | Команды | Komutlar | 命令 | 命令 |
| `pal.field` | Card number, title or action | Número do card, título ou ação | Número de tarjeta, título o acción | Numéro de carte, titre ou action | Kartennummer, Titel oder Aktion | Numero della card, titolo o azione | カード番号、タイトル、操作 | 카드 번호, 제목 또는 동작 | Номер карточки, название или действие | Kart numarası, başlık veya eylem | 卡片编号、标题或操作 | 卡片編號、標題或操作 |
| `pal.next` | Next decision | Próxima decisão | Siguiente decisión | Décision suivante | Nächste Entscheidung | Prossima decisione | 次の判断 | 다음 결정 | Следующее решение | Sonraki karar | 下一个决定 | 下一個決定 |
| `pal.live` | Back to live | Voltar ao vivo | Volver al directo | Revenir au direct | Zurück zu live | Torna alla diretta | ライブに戻る | 실시간으로 돌아가기 | Вернуться к текущему | Canlıya dön | 返回实时 | 返回即時 |
| `pal.at` | See the line at {time} | Ver a esteira às {time} | Ver la línea a las {time} | Voir la chaîne à {time} | Die Linie um {time} zeigen | Vedi la linea alle {time} | {time} のラインを見る | {time}의 라인 보기 | Показать линию в {time} | Hattı {time} saatinde gör | 查看 {time} 的流水线 | 查看 {time} 的產線 |
| `pal.pause` | Pause the factory | Pausar a fábrica | Pausar la fábrica | Mettre l'usine en pause | Fabrik pausieren | Metti in pausa la fabbrica | ファクトリーを一時停止 | 팩토리 일시 중지 | Приостановить фабрику | Fabrikayı duraklat | 暂停工厂 | 暫停工廠 |
| `pal.none` | Nothing matches | Nada encontrado | Sin resultados | Aucun résultat | Keine Treffer | Nessun risultato | 一致するものはありません | 일치하는 항목 없음 | Ничего не найдено | Eşleşme yok | 没有匹配项 | 沒有相符項目 |
| `pal.count` | {n, plural, one {# result} other {# results}} | {n, plural, one {# resultado} other {# resultados}} | {n, plural, one {# resultado} other {# resultados}} | {n, plural, one {# résultat} other {# résultats}} | {n, plural, other {# Treffer}} | {n, plural, one {# risultato} other {# risultati}} | {n, plural, other {# 件}} | {n, plural, other {결과 #개}} | {n, plural, one {# результат} few {# результата} many {# результатов} other {# результата}} | {n, plural, other {# sonuç}} | {n, plural, other {# 个结果}} | {n, plural, other {# 個結果}} |

## Architecture
_Tech Lead_

One layer: `factory` (path `./`). Builds on #182's work-area selection (the one call that selects a card) and, for "stopped", on #176's dispatcher-stopped signal.

**Contracts touched**
- `<home>/dashboard.port` (new home file): the port the dashboard bound, one line, written after the bind (temp file + `os.replace`), removed on a clean exit. A stale file only yields a link that does not load.
- `SHIPFLOOR_NOTIFY_SEND` seam: called as `<command> <channel> <title> <body> <click>`; `<click>` is the link or `""`. The test senders that read only `$1..$3` keep working.
- ntfy push: header `Click: http://127.0.0.1:<port>/#card/<n>` on a card's wait and reminder messages (waiting and blocked) when `dashboard.port` holds a port in 1–65535; never on the digest, stuck or done messages, never on the toast.
- Page address: `#card/<n>` (pushState on a selection, popstate restores it); `#@HHMM` is parsed and reserved for #184. The token is never in the hash or in the push.
- Page token: the page saves the `?t=` token in `localStorage` (`shipfloor.token`) and uses it when the URL has none, so a push link without a token opens a working page on the same origin.

**Files**
- `scripts/dashboard.py`: `main()` writes and removes `<home>/dashboard.port`.
- `scripts/shipfloor_notify.py`: `click_url(home, n)` reads the port file; `send()` takes `click` and adds the header (ntfy) or the `<click>` argument (seam); `wait_message` callers pass it.
- `scripts/dashboard.html`: pure functions the tests run in node: `tabState(overview, project)` → `{count, stopped}`, `tabTitle(state, project)`, `parseHash(hash)` → `{card}`, `{at}` or `null`, `hashOf(sel)`, `palette(query, cards, actions)` → at most nine rows; plus `favicon()` taking the state, the header button, the palette dialog, the Ctrl K / Cmd K handler (before the single-letter keys), `hashchange`/`popstate` handling and the token fallback. `stopped` is #176's signal when it is on main at develop time, else `stale(project())`. Palette actions call the same handlers as their buttons; replay actions are listed only when a `REPLAY` hook (set by #184) exists.
- `scripts/lang/dashboard.{en,pt-BR,es,fr,de,it,ja,ko,ru,tr,zh-CN,zh-TW}.json`: the nine keys of `## UX`.
- `docs/operation.md`: the tab, the address, the palette, the push link that opens only on this machine, `dashboard.port`.
- `docs/contracts.md`: the seam's new argument.
- `DESIGN.md`: the tab, address and palette rules (they leave floor-v4 when shipped).
- Tests: `scripts/test/dashboard-views.test.sh` (extended: the file-count ceiling in `hygiene.test.sh` forbids new files), `scripts/test/notify.test.sh` (sender records `$4`).

**Migration:** none; no data changes. Reverting leaves a harmless `dashboard.port` and `shipfloor.token` in storage.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-5 | factory | `scripts/test/notify.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-views.test.sh` |
| AC-8 | factory | `scripts/test/dashboard-views.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The push link carries no token; the page keeps the last token in `localStorage`: putting the dashboard secret in a message sent through ntfy.sh would hand it to a third party.
- The port reaches the notifier through `<home>/dashboard.port`: the dashboard tries 10 ports from 7717, so only the running server knows which one it bound.
- The replay hash `#@HHMM` and the replay actions are deferred to #184 (UX-10): the replay does not exist yet and #184 is ordered after this card; this card parses the hash and leaves a hook.
- AC-2 names the catalog key `title.stopped`, not the pt-BR word: the page title follows the dashboard's language.
- "Stopped" uses #176's signal when it is merged, else today's stale-board check: both depend on the dispatcher's snapshot age, and #176 is ahead in the queue.
- The title counts and names the project the page shows (`#scope`), the same count as the waiting list, so the tab never disagrees with the page.
- Only a card's wait and reminder pushes get `Click`: the digest and stuck messages have no single card to open.
- Favicon stays the brand tile, recoloured by state (UX): a 4px square on a 16px icon is unreadable.
- Page logic is tested as pure functions run in node (skipped without node, as `dashboard-glance.test.sh` does) plus static checks of the markup: the factory has no browser in headless runs.
- This card waits for #182 (UX-08) to merge before develop: the address stores the work area's selection.

## Open questions
- none
