# Owner approves one extra amendment of the acceptance tests per card (label qa-amend-ok), without touching the global limit — spec

**Issue:** #204 · **Branch:** `feat/204-dono-aprova-uma-alteracao-extra-dos-test` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** When the `qa-amend` gate blocks a card ("the owner decides now"), the owner has no way to decide for that one card; the only exits are raising `FACTORY_QA_AMEND_MAX` for every card and project, or redoing the card by hand (Pickio #144 and #181 were stuck this way).
**Audience:** The factory's owner.
**Acceptance criteria**
- **AC-1** — Given a card at the amendment limit with `qa-amend-ok` added by the owner, when the QA amends the acceptance tests again, then `qa-amend` passes once (QA commit and no-removed-assertion checks still apply) and the label is removed from the issue.
- **AC-2** — Given that same card after the approved extra amendment, when the QA amends the acceptance tests once more, then `qa-amend` blocks again.
- **AC-3** — Given a card at the limit with `qa-amend-ok` added by anyone other than the owner (per the issue's REST events), when the gate runs, then the label is ignored and the gate blocks.
- **AC-4** — Given a card without `qa-amend-ok`, when the gate runs, then behaviour is unchanged and `FACTORY_QA_AMEND_MAX` still sets the limit.
- **AC-5** — Given a card blocked by `qa-amend`, when the owner reads the block message, then it tells them how to approve: the `qa-amend-ok` label or the dashboard button.
- **AC-6** — Given the test suite, when it runs, then `fake-gh` tests cover AC-1 to AC-4.
- **AC-7** — Given a card blocked by `qa-amend`, when the owner opens its review page in the dashboard, then it shows the acceptance-test diff against the previous QA commit and an "Approve this amendment" button that adds `qa-amend-ok` and removes `blocked`.
- **AC-8** — Given an extra amendment accepted by the label, when the card report and the factory's issue comment are written, then they say the owner approved the extra amendment via `qa-amend-ok`; and `setup-board` creates the `qa-amend-ok` label.

**Out of scope:** Changing the default or semantics of `FACTORY_QA_AMEND_MAX`; approving more than one extra amendment per label; per-project limit settings; recovering commits lost on the old machine.
**Product fit:** Serves principle 2 (the gate, not the agent, still decides; a script checks the label author) and principle 4 (the owner acts only where the factory waits for them, and now can). Adds a new owner-only action ("approve this amendment" on a `qa-amend`-blocked card) to the list in PRODUCT.md; the button writes only to the board (label + `blocked`), so principle 1 holds. No conflict with positioning.
**Touches UI:** yes

## UX
_UX/UI Designer_

- **AC-5, the block message** (gate stderr, English only like every gate line; it reaches the issue comment and the drawer's block note): `qa-amend: the acceptance tests of #<n> were already amended <max> times; the owner decides now. To allow one more amendment, add the label qa-amend-ok to the issue, or press "Approve this amendment" on the card in the dashboard.`
- **Where (AC-7):** a blocked card has no agent-written review page, so the "review page" is the existing **block note** in the drawer head (`blockNote()`). It changes only when the failed gate is `qa-amend` *and* the reason holds "the owner decides now". Every other block stays as it is.
- **Flow:** 1. The owner opens the blocked card (it opens the wide drawer like any card waiting for them). 2. The block note shows the lead line and the failed gate, as today. 3. Under them, a `<details>` that starts open: summary `amend.diff`, body the unified diff of the acceptance test files, newest QA commit against the one before. 4. **Approve this amendment** replaces **Unblock & retry** in the note's button slot. 5. On click, the server adds `qa-amend-ok` and removes `blocked`. The note shows `amend.done` and the card leaves the blocked state on the next refresh.
- **Components and tokens:** the button is `button-approve` (`text` fill, `ground` ink, `rounded.md`), not the list pill. The diff reuses `.block-note .md pre` (`ground` well, `log` mono 12px, `rounded.sm`, `pre-wrap`) with `max-height: 16em; overflow: auto`. Added lines get `color: var(--ok)`, removed lines `var(--bad)` and hunk headers `muted` (outcome colors, since the diff shows a result). Each line also keeps its `+`/`-` prefix, so the meaning does not rest on color alone. The diff is `RAW` and never translated. No new component.
- **States:** *Loading:* while the request runs, the button is disabled with the progress cursor and keeps its label. Until the diff arrives with the card read, the `<details>` body reads `amend.reading` in `muted`. *Error:* a refused or failed write puts `amend.failed` in the existing `#bn-err` status line (`bad`) and enables the button again. A diff that cannot be read shows `amend.nodiff` in `muted`, and the button stays available (the gate keeps its own checks). *Success:* `amend.done` takes the button's place, and the note goes away on the next refresh. If the issue already has `qa-amend-ok` (added by hand) and is still blocked, the note keeps the usual **Unblock & retry**, so the label is never added twice.
- **Small screen:** under 540px of drawer width the existing `.block-note` stacked rule applies (the button under the text, left-aligned). The diff scrolls sideways inside its `pre`, never the drawer. The button keeps the 24x24 target and the `sand` focus ring.
- **Copy, new keys** (`scripts/lang/dashboard.<code>.json`; en first):
  - `amend.approve`: en "Approve this amendment" · de "Diese Änderung genehmigen" · es "Aprobar esta modificación" · fr "Approuver cette modification" · it "Approva questa modifica" · ja "この修正を承認" · ko "이 수정 승인" · pt-BR "Aprovar esta alteração" · ru "Одобрить эту правку" · tr "Bu değişikliği onayla" · zh-CN "批准此次修改" · zh-TW "核准此次修改"
  - `amend.diff`: en "Acceptance tests changed since the previous QA commit" · de "Abnahmetests seit dem vorherigen QA-Commit geändert" · es "Pruebas de aceptación cambiadas desde el commit de QA anterior" · fr "Tests d'acceptation modifiés depuis le commit QA précédent" · it "Test di accettazione cambiati dal commit QA precedente" · ja "前回の QA コミットからの受け入れテストの変更" · ko "이전 QA 커밋 이후 변경된 인수 테스트" · pt-BR "Testes de aceitação alterados desde o commit de QA anterior" · ru "Приёмочные тесты, изменённые с предыдущего QA-коммита" · tr "Önceki QA commit'inden bu yana değişen kabul testleri" · zh-CN "自上次 QA 提交以来更改的验收测试" · zh-TW "自上次 QA 提交以來變更的驗收測試"
  - `amend.done`: en "Amendment approved; the factory retries the card." · de "Änderung genehmigt; die Fabrik versucht die Karte erneut." · es "Modificación aprobada; la fábrica reintenta la tarjeta." · fr "Modification approuvée ; l'usine relance la carte." · it "Modifica approvata; la fabbrica riprova la card." · ja "修正を承認しました。ファクトリーがカードを再試行します。" · ko "수정이 승인되었습니다. 팩토리가 카드를 다시 시도합니다." · pt-BR "Alteração aprovada; a fábrica tenta o card de novo." · ru "Правка одобрена; фабрика повторит карточку." · tr "Değişiklik onaylandı; fabrika kartı yeniden deneyecek." · zh-CN "修改已批准；工厂将重试该卡片。" · zh-TW "修改已核准；工廠將重試該卡片。"
  - `amend.failed` (`{reason}` is raw): en "Not approved: {reason}" · de "Nicht genehmigt: {reason}" · es "No aprobado: {reason}" · fr "Non approuvé : {reason}" · it "Non approvato: {reason}" · ja "承認されませんでした：{reason}" · ko "승인되지 않음: {reason}" · pt-BR "Não aprovado: {reason}" · ru "Не одобрено: {reason}" · tr "Onaylanmadı: {reason}" · zh-CN "未批准：{reason}" · zh-TW "未核准：{reason}"
  - `amend.nodiff`: en "The diff could not be read; see the branch on GitHub." · de "Der Diff konnte nicht gelesen werden; siehe den Branch auf GitHub." · es "No se pudo leer el diff; mira la rama en GitHub." · fr "Impossible de lire le diff ; voir la branche sur GitHub." · it "Impossibile leggere il diff; vedi il branch su GitHub." · ja "差分を読み込めませんでした。GitHub のブランチを確認してください。" · ko "diff를 읽을 수 없습니다. GitHub에서 브랜치를 확인하세요." · pt-BR "Não foi possível ler o diff; veja o branch no GitHub." · ru "Не удалось прочитать diff; смотрите ветку на GitHub." · tr "Diff okunamadı; GitHub'daki branch'e bakın." · zh-CN "无法读取差异；请在 GitHub 上查看该分支。" · zh-TW "無法讀取差異；請在 GitHub 上查看該分支。"
  - `amend.reading`: en "Reading the diff…" · de "Diff wird gelesen…" · es "Leyendo el diff…" · fr "Lecture du diff…" · it "Lettura del diff…" · ja "差分を読み込み中…" · ko "diff를 읽는 중…" · pt-BR "Lendo o diff…" · ru "Читаю diff…" · tr "Diff okunuyor…" · zh-CN "正在读取差异…" · zh-TW "正在讀取差異…"

## Architecture
_Tech Lead_

All in layer `factory`. No endpoint, event or schema migration; one new local record file.

**Contracts touched**
- Gate `qa-amend <n>` (`scripts/shipfloor_core/gate/acceptance.py`, `qa_amend`): same usage and exit codes, plus exit 3 when GitHub cannot be read or the label cannot be removed. New order: when `len(qa_commits) > FACTORY_QA_AMEND_MAX + 1`, look for an approval *before* failing:
  1. HEAD's SHA already recorded for `#<n>` in `<FACTORY_HOME>/qa-amend-ok.tsv` → approved (a rerun of the same commit, after the label was used).
  2. Else the issue has label `qa-amend-ok` and the newest `labeled` event for it in `GET repos/<repo>/issues/<n>/events` (paginated) has an `actor.login` in the trusted set → approved, pending.
  3. Else → fail with the AC-5 message (unchanged text plus the "To allow one more amendment…" sentence).
  With an approval, the other checks (QA-scope files, switched-off tests, assertion count) run as today; only if they all pass does a pending approval get used: `DELETE repos/<repo>/issues/<n>/labels/qa-amend-ok`, then append `#<n>\t<head sha>\t<actor>\t<iso time>` to `qa-amend-ok.tsv`. Pass line: `qa-amend: ok, <a> assertion lines replaced by <b>; one amendment over the limit approved by the owner (qa-amend-ok)`.
- Trusted set: the `gh api user` login plus `trusted_commenters`, the same set `board.issue` uses; extract it from `board.py` into one helper (`board.trusted_logins()`) that both call.
- `scripts/lang/pt-BR.sed`: the new block sentence and the new pass suffix.
- `setup-board` (`scripts/shipfloor_core/setup.py` `_LABELS`): adds `("qa-amend-ok", "0E8A16", "The owner allows one more amendment of this card's acceptance tests")`.
- Dashboard (`scripts/dashboard.py`): `block()` sets `gate: "qa-amend"` when the reason holds `qa-amend` and `the owner decides now`, with `diff` = `git diff <previous QA commit> <newest QA commit> -- <acceptance files>` (via `gate.sh qa-commit`, capped 8000 chars, cached 60 s like `acceptance_diff`); new POST action `approve-amend` on `/api/<p>/card/<n>/` → `gh api repos/<repo>/issues/<n>/labels -f labels[]=qa-amend-ok`, then `unblock()`; 409 if the card is not blocked, 502 with gh's error if the label write fails (nothing unblocked). `scripts/dashboard.html`: the block note per `## UX`; six `amend.*` keys in `scripts/lang/dashboard.<code>.json` (12 files).
- Skills: `skills/develop/SKILL.md` and `skills/validate/SKILL.md` — (a) a resumed card whose last commit is a QA amendment (more than one QA commit, HEAD one of them) runs `gate.sh qa-amend <n>` before anything else; (b) when the gate prints `approved by the owner (qa-amend-ok)`, the "Acceptance tests amended by QA" comment and the report's `amendments` entry say the extra amendment was approved by the owner with `qa-amend-ok`.
- Docs: `docs/contracts.md` (`qa-amend` rule, the label, `qa-amend-ok.tsv`, the new dashboard action), `docs/operation.md` (how to approve), `PRODUCT.md` owner-only actions list (one line).
- Test double: `scripts/test/fake-gh` answers `api repos/acme/shop/issues/<n>/events` from `$d/events-<n>` (default `[]`) and records label DELETEs in `$d/calls` (already logged).

**Files:** `scripts/shipfloor_core/gate/acceptance.py`, `scripts/shipfloor_core/board.py`, `scripts/shipfloor_core/setup.py`, `scripts/lang/pt-BR.sed`, `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.*.json`, `skills/develop/SKILL.md`, `skills/validate/SKILL.md`, `docs/contracts.md`, `docs/operation.md`, `PRODUCT.md`, `scripts/test/fake-gh`, tests below.

**Migration:** none; `qa-amend-ok.tsv` is created on first use, and an absent file means no approvals.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/py/gate_accept.py` |
| AC-2 | factory | `scripts/test/py/gate_accept.py` |
| AC-3 | factory | `scripts/test/py/gate_accept.py` |
| AC-4 | factory | `scripts/test/py/gate_accept.py` |
| AC-5 | factory | `scripts/test/py/gate_accept.py` |
| AC-6 | factory | `scripts/test/py/gate_accept.py` |
| AC-7 | factory | `scripts/test/py/dashboard_cards.py` |
| AC-8 | factory | `scripts/test/py/board_write.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- AC-7's "review page" is the drawer's existing block note: a blocked card has no review page, and the note is where the owner already decides a block (UX).
- After "Approve this amendment" the card stays in its column (Coding or Validation) and only `blocked` comes off: the dispatcher re-runs that stage, which re-runs `qa-amend` first on a resumed card.
- "Owner" for the label is the same trusted set as for comments (`gh api user` + `trusted_commenters`): the issue asks for the same "listens only to you" rule, and one helper keeps both in step.
- The label is used only after every other `qa-amend` check passes: a label spent on an amendment that then fails for another reason would force the owner to approve twice.
- The used approval is recorded by HEAD SHA in `<FACTORY_HOME>/qa-amend-ok.tsv`: `validate` reruns gates, and a rerun of the same approved commit must pass after the label is gone; a new commit is not in the file, so AC-2 holds.
- A label present while the card is still under the limit is left untouched: it is only spent when it is needed.
- GitHub unreadable or the label DELETE failing → exit 3 (infra), nothing recorded: the gate never passes on an approval it could not verify or spend.
- The pass and block lines get their pt-BR translation in `scripts/lang/pt-BR.sed`, like every other `qa-amend` line (UX's "English only" refers to the dashboard, where gate text stays raw).
- PRODUCT.md's owner-only actions list gets the new action in this card (one line), so product context stays true.
- AC-8's "report and comment" part is skill text (develop/validate) checked in review; its automated row tests `setup-board` creating the label.
- Existing suites only: `gate_accept.py` already covers `qa-amend`, `dashboard_cards.py` the block note and `accept`, `board_write.py` `setup-board`'s labels.

## Open questions
- none
