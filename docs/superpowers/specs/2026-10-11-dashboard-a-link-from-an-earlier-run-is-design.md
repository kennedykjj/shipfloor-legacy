# Dashboard: a link from an earlier run is a dead end and keeps polling — spec

**Issue:** #52 · **Branch:** `feat/52-dashboard-a-link-from-an-earlier-run-is` · **Date:** 2026-10-11
**Roles:** PO, Tech Lead, UX/UI

## Product
_Product Owner_

**Problem:** Every `shipfloor dashboard` run makes a new link, so a tab left open from the previous run is refused (403), shows one sentence with nothing to act on, and keeps asking the server every few seconds. The owner has to go back to the terminal for a new URL.
**Audience:** The factory's owner, who keeps a dashboard tab open for quick checks between restarts.
**Acceptance criteria**
- **AC-1** — Given the dashboard ran once on a home, when it is stopped and started again on the same home and port, then the URL it prints is the same as the one printed before.
- **AC-2** — Given a tab open on a dashboard that was then restarted on the same port, when the server is back, then the tab shows the factory again without a reload or a new URL.
- **AC-3** — Given a tab whose link the server refuses with 403, when the first 403 arrives, then the page sends no further request of any kind (overview, feed, card, log, settings) until it is reloaded.
- **AC-4** — Given a tab whose link was refused, when the owner reads the page, then it says the link is no longer valid and shows the command to run (`shipfloor dashboard`) to get the current one, with no factory data on screen.
- **AC-5** — Given a home with no saved link secret (first run, or the owner deleted it), when the dashboard starts, then it creates a new one, starts normally and prints the URL.
- **AC-6** — Given a running dashboard, when a request reaches the API with no token or a wrong one, then it is still answered 403, exactly as today.
- **AC-7** — Given a dashboard that is stopped, when a tab is open on it, then the tab shows the existing "server is not answering" state and keeps trying, as today (only a 403 stops the page).
**Out of scope:** Following the dashboard to a different port (a tab on port A does not find a server that came back on port B); a command or button to rotate the link (deleting the saved secret and restarting is the way); expiring the link by age; handing the current URL to a refused tab from the server; any change to the review pages beyond their using the same link.
**Product fit:** Serves "the dashboard is used in quick checks: open it, approve what is waiting, close it" and principle 4 (the owner acts only where the factory waits for the owner): a restart stops costing a trip to the terminal. Stays inside "local only (127.0.0.1)" and adds no card state to the dashboard (principle 1). Trade-off stated plainly: the link stops being single-run, so a URL that leaked once stays valid on that machine until the owner deletes the saved secret; accepted because the server listens on loopback only and the secret is kept with the same protection as the rest of `~/.shipfloor`.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **Flow:** the first 403 on any request (overview, lang, feed, card, log, live, settings, a decision) puts `scripts/dashboard.html` in one final state, the refused link; it is the same state whichever request was refused, and only a reload leaves it. A reload with the same URL lands on it again.
- **What stays on screen:** the header with the brand only, and the existing `#msg` (`.placeholder`: 20px padding, 64ch) as the whole page. No new component, no button, no icon.
- **What goes away (AC-4):** `.views`, `.stats` (`#scope`, `#stats`), `#alerts` emptied (no Offline, Not updating, paused or stale-board flag), `#band`, `#cols`, `#feed`, `#settings`, `#peek`, and `#drawer` closed and `inert`, the maximized scrim included. The Review iframe is removed from the document, not just hidden: it asks the server on its own (AC-3). The keys n, a, r, l and Esc do nothing.
- **Content of `#msg`, three pieces, each its own text node so each is one `exact` catalog entry (the command sits on its own line, never inside a sentence):** a first line in `--text`, 600, 14px; a sentence in `--muted`; the command; a closing sentence in `--muted`.
- **Copy, en:** "This link is no longer valid" / "The dashboard does not accept it any more, so this page stopped updating. To get the current link, run in a terminal:" / `shipfloor dashboard` / "Then open the URL it prints. This tab stays as it is."
- **Copy, pt-BR (`scripts/lang/dashboard.pt-BR.json`, `exact`):** "Este link não é mais válido" / "O dashboard não o aceita mais, então esta página parou de atualizar. Para pegar o link atual, rode no terminal:" / `shipfloor dashboard` / "Depois abra a URL que ele imprimir. Esta aba fica como está."
- **The command:** a `<code>` on its own line (mono 13px, `--text` on `--panel-hi`, 1px `--edge-hi`, 4px radius, 2px 7px padding) with `user-select: all`, so one click selects it whole for Ctrl/Cmd+C. No copy button: the page has no clipboard code today and two words do not earn it. `code` is already in `RAW`, so it is never translated.
- **Language on a cold open:** a tab opened with a refused link never gets the catalog (`/api/lang` is refused too, and stays so under AC-6), so it reads in English; a tab refused while open already has the catalog and reads in the machine's language. Accepted: it is the documented fallback ("one with no entry shows in English") and the command is the same in both.
- **Accessibility:** on entering the state `#msg` gets `role="alert"` and `tabindex="-1"` and takes focus (an open drawer or settings field would otherwise leave focus on a hidden element); the markup is written once, so it is announced once. Tab then reaches nothing else. The first line is a `<strong>`, not a heading: the page keeps no other heading in this state.
- **Color:** tokens only (`--text`, `--muted`, `--panel-hi`, `--edge-hi`); no `--bad`, no accent (`--sand`), no gold. The link is not an outcome of the factory and nothing here waits for a decision. These are the text steps `scripts/test/theme.test.sh` already holds to 4.5:1 in the 12 themes; the theme from `localStorage` still applies.
- **Other states:** none of its own (no loading, empty or success). On a cold open it replaces "Reading the factory…" at the first answer. AC-7 is untouched: a server that does not answer keeps the Offline flag and the retries, and never shows this state.
- **Small screen:** one column, the text wraps inside the 20px padding and the command does not wrap (it fits at 320px); no breakpoint of its own.

## Architecture
_Tech Lead_

One layer, `factory`. No endpoint, event or config key changes; no migration.

**`scripts/dashboard.py`**
- New `link_token(home) -> str`: reads `<home>/dashboard.token`; a value matching `[A-Za-z0-9_-]{22}` is returned as is, anything else (missing, empty, damaged) is replaced by a fresh `secrets.token_urlsafe(16)`.
- The file is written to a sibling temp file created with `os.open(..., O_WRONLY | O_CREAT | O_EXCL, 0o600)` and moved in with `os.replace`, so it is never readable by others and never half-written. Its content is the token and a newline.
- A home that cannot be written does not stop the start: the token lives in memory for that run and one line on stderr says the link will not survive a restart.
- `main()`: `Handler.token = link_token(args.home)` replaces the `secrets.token_urlsafe(16)` call. The printed line (`shipfloor dashboard: <url>  (Ctrl+C stops it)`) and `Handler.allowed()` are unchanged, so every 403 stays as it is.
- The token is never logged, never sent in a response body and never served by any route (`/api/log` only reads under `logs/`).

**`scripts/dashboard.html`**
- `S.refused` (false at load). `api()` is the page's only `fetch`: when `S.refused` is set it returns `{ status: 403, body: {} }` without a request; when a response is 403 it sets `S.refused` and calls `refuse()` once. A network failure (the `catch`) leaves `S.refused` alone, so the Offline flag and its retries stay as today.
- `refuse()` draws the refused-link state of `## UX` and removes what could still ask the server or show factory data: the drawer with its review iframe (the iframe's `src` carries the token and loads on its own), the settings view, the flags. The 403 branch of `loadOverview` moves into it.
- The timers are left running; they reach `api()` and stop there. One guard covers the seven intervals and every owner action.

**`skills/dashboard/SKILL.md`**: "The URL holds this run's token" becomes "this machine's token". **`README.md`**: one line under the dashboard on where the link's secret is kept and that deleting it makes a new link.

**`scripts/lang/dashboard.pt-BR.json`**: the three `exact` entries of `## UX` (the sentence shown today has no entry to remove).

Files and owners (`shipfloor-config.sh layer-of`): `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.pt-BR.json`, `scripts/test/dashboard-link.test.sh` (new), `README.md`, `skills/dashboard/SKILL.md`: all `factory`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/dashboard-link.test.sh` |
| AC-2 | factory | `scripts/test/dashboard-link.test.sh` |
| AC-3 | factory | `scripts/test/dashboard-link.test.sh` |
| AC-4 | factory | `scripts/test/dashboard-link.test.sh` |
| AC-5 | factory | `scripts/test/dashboard-link.test.sh` |
| AC-6 | factory | `scripts/test/dashboard-link.test.sh` |
| AC-7 | factory | `scripts/test/dashboard-link.test.sh` |

How each is checked, in that one file (a temp `SHIPFLOOR_HOME`, the fake `gh`, `--port 0 --no-open`, as `dashboard.test.sh` starts it):
- AC-1: start, read the URL, stop, start again on the same port: the two URLs are equal.
- AC-2: the token of the first run gets 200 from `/api/overview` of the second run (the page side is the polling that exists today, kept by AC-7).
- AC-3, AC-4, AC-7: read from the source of `dashboard.html` with Python, as `theme.test.sh` does: the page has exactly one `fetch(`, inside `api()`; the `S.refused` guard comes before it; a 403 response sets it; the `catch` branch does not; the refused state's text names `shipfloor dashboard`. The screen itself is checked by UX in validation.
- AC-5: with `dashboard.token` deleted, and again with it damaged, the start prints a URL with a new token, the old token gets 403 and the file is back; where the system has file modes, the file is `600`.
- AC-6: no token and a wrong token get 403 on a GET and on a POST; the token in the URL of a POST still gets 403.

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The link's secret is kept in `<home>/dashboard.token`, one per machine: the issue asks for it, and it is what lets an open tab survive a restart.
- A leaked URL stays valid until the file is deleted: accepted because the issue proposes it, the server listens on 127.0.0.1 only and the token already sits in the browser's history and the terminal's scrollback today.
- The file is created `0600` and replaced atomically: the rest of the home has no file protection of its own (no `chmod` anywhere in `scripts/`), so "the same protection as the home" would be none on a shared Linux or macOS machine; on Windows the user profile's ACL covers it.
- No rotate command, button or expiry: deleting the file and restarting makes a new link; a flag can come later if it is ever asked for.
- Same port only: when 7717 is taken the dashboard moves to the next port and an old tab shows Offline, as today; following the port would need the tab to scan ports.
- Only a 403 stops the page; a server that is not answering keeps the retries, otherwise a tab could not come back after a restart.
- The stop is one guard in `api()`, not seven `clearInterval` calls: `api()` is the page's only `fetch`, so nothing new can poll past it.
- The refused state also removes the open drawer and its review iframe: the iframe asks the server on its own and would show factory data under the message.
- The server never hands the current URL to a refused tab: that would give the token to whoever asks without it.
- A home that cannot be written still starts, with a token for that run only and a warning: the dashboard is the owner's way to see what is wrong with the factory.
- AC-3, AC-4 and AC-7 are tested on the page's source, not in a browser: the `factory` layer has no JavaScript runtime (Bash and Python only) and `theme.test.sh` already tests the page this way; UX checks the real screen in validation.
- The command is a `<code>` selected whole by one click, with no copy button: the page has no clipboard code and two words do not earn it.
- A tab opened cold with a refused link reads in English: `/api/lang` is refused too and stays so (AC-6); serving the catalog without a token or inlining the strings would each break a rule for three sentences.
- No `## Security` review: the issue has no `cybersec` label; the trade-off is recorded above.
- Rollback is n/a: reverting the change makes the server ignore `dashboard.token`; the leftover file is harmless.

## Open questions
- none
