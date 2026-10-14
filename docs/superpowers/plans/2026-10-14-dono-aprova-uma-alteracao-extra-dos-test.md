# Plan — #204 Owner approves one extra amendment of the acceptance tests (qa-amend-ok)

Spec: `docs/superpowers/specs/2026-10-14-dono-aprova-uma-alteracao-extra-dos-test-design.md`
Layers: `factory` only (path `./`, agent `engineer`). Tasks run one at a time in the shared worktree.

## T1 — Gate, trusted set, label, test double (factory, engineer)
- `scripts/shipfloor_core/board.py`: extract `trusted_logins()` (gh `api user` login + `trusted_commenters`); `issue` uses it.
- `scripts/shipfloor_core/gate/acceptance.py` `qa_amend`: over the limit, approval lookup (record file `<FACTORY_HOME>/qa-amend-ok.tsv` by HEAD SHA, else label `qa-amend-ok` whose newest `labeled` event actor is trusted); other checks run; then spend (DELETE label, append record) and the pass suffix; AC-5 block message; exit 3 when GitHub cannot be read or the DELETE fails.
- `scripts/lang/pt-BR.sed`: new block sentence and pass suffix.
- `scripts/shipfloor_core/setup.py` `_LABELS`: `qa-amend-ok`.
- `scripts/test/fake-gh`: `issues/<n>/events` from `$d/events-<n>` (default `[]`); label DELETE logged in `$d/calls`.
- ACs: AC-1..AC-6, AC-8 (setup-board label). Depends on: QA commit.

## T2 — Dashboard block note and approve action (factory, engineer)
- `scripts/dashboard.py`: `block()` gives `gate: "qa-amend"` + `diff` (previous vs newest QA commit, acceptance files, 8000 chars, 60 s cache); POST `approve-amend` (label write, then `unblock()`; 409 not blocked, 502 on gh error).
- `scripts/dashboard.html`: block note per spec `## UX` (details with diff, `button-approve`, states).
- `scripts/lang/dashboard.*.json` (12 files): six `amend.*` keys.
- ACs: AC-7. Depends on: T1 (trusted helper not needed; label name shared).

## T3 — Skills and docs (factory, engineer)
- `skills/develop/SKILL.md`, `skills/validate/SKILL.md`: resumed card with a QA amendment as HEAD runs `gate.sh qa-amend <n>` first; the "approved by the owner (qa-amend-ok)" line goes into the amendment comment and the report's `amendments`.
- `docs/contracts.md`, `docs/operation.md`, `PRODUCT.md` (one line in owner-only actions).
- ACs: AC-8 (text part, checked in review). Depends on: T1, T2.
