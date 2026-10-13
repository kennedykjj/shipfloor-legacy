# Remove the temporary AGHANIM_* stack aliases — spec

**Issue:** #46 · **Branch:** `feat/46-remove-the-temporary-aghanim-stack-alias` · **Date:** 2026-10-12
**Roles:** PO, Tech Lead

## Product
_Product Owner_

**Problem:** The rename to Shipfloor (#45) left temporary bridges to the old name: every stack slot still exports `AGHANIM_*` beside `SHIPFLOOR_*`, and the CLI, installer and install guide still carry upgrade paths from Aghanim's Anvil. They were meant to live only while pre-rename card branches were open; kept longer, they are dead surface a new installer has to read past and a second name the product no longer has.
**Audience:** The factory's owner and other developers who install the plugin.
**Acceptance criteria**
- **AC-1** — Given a stack slot, when the `stack` gate runs the project's `up` command, then its environment has `SHIPFLOOR_STACK`, `SHIPFLOOR_STACK_URL` and `SHIPFLOOR_PORT_*` and no variable whose name starts with `AGHANIM_`.
- **AC-2** — Given the CLI, when the owner runs `shipfloor migrate-home`, then it fails as an unknown command, and `shipfloor help` does not list it.
- **AC-3** — Given a home that still has a `~/.aghanim` directory, when the owner runs `shipfloor doctor`, then the output has no warning about it and the directory is left untouched.
- **AC-4** — Given the Windows installer, when `installer/install-dispatcher.ps1` registers the dispatcher, then it neither looks up nor removes a scheduled task named `AghanimDispatcher`.
- **AC-5** — Given the docs, when a developer reads `docs/install.md` and `README.md`, then there is no "Upgrading from Aghanim's Anvil" section and no mention of `migrate-home`.
- **AC-6** — Given old run logs whose commands are `/aghanim:*` or `/mylos:*`, when the dashboard computes cost, then those runs are still attributed to their stage and card as before.
- **AC-7** — Given the repository, when the hygiene test runs, then it passes, and the old names remain only on lines marked `legacy aghanim` / `legacy mylos`, all of them the dashboard's old-log readers.
**Out of scope:** Checking or updating branches of other registered projects (Pickio) that still read `AGHANIM_*`: assumed already clear, verified by the Tech Lead before this ships, not by this change. Migrating or deleting an existing `~/.aghanim` home or an existing `AghanimDispatcher` task on anyone's machine. Rewriting old logs. Any change to the dashboard's behavior or to the `SHIPFLOOR_*` names.
**Product fit:** Serves the brand commitment (one name: Shipfloor, CLI `shipfloor`) and principle 3, "numbers are exact and sourced": the cleanup must not drop cost history, so the old-log readers stay. No conflict with positioning. One accepted cost: an owner who never upgraded from Aghanim's Anvil loses the assisted path and must move the home by hand.
**Touches UI:** no

## UX
_UX/UI Designer_ — n/a

## Architecture
_Tech Lead_

Pure removal: no new code, no new contract, no data migration. One layer, `factory`, owns every file.

**Contracts touched**
- Stack slot environment (`slot_env`, read by a project's `stack.up`, `stack.down`, tests and agents): `AGHANIM_STACK`, `AGHANIM_STACK_URL` and `AGHANIM_PORT_<NAME>` are no longer exported. `SHIPFLOOR_SLOT`, `SHIPFLOOR_STACK`, `SHIPFLOOR_STACK_URL` and `SHIPFLOOR_PORT_<NAME>` are unchanged.
- CLI `shipfloor`: the `migrate-home [OLD]` command is gone; it falls into the unknown-command branch (usage on stderr, exit 2). `doctor` no longer prints the `~/.aghanim` warning.
- Unchanged on purpose: `RUN_LINE` in `scripts/dashboard.py` and `COMMAND` / `LEGACY_STAGES` in `scripts/dashboard_cost.py` keep matching `/aghanim:` and `/mylos:`.

**Files changed**
- `scripts/lib/stack.sh`: delete the two `# legacy aghanim` lines at the end of `slot_env`.
- `scripts/shipfloor`: delete the `migrate-home` header line, `cmd_migrate_home`, its `case` arm and the `~/.aghanim` block in `cmd_doctor`; reword the "drop what the plugin no longer ships" comment in `cmd_install` so it names neither the old name nor `migrate-home` (the cleanup itself stays).
- `installer/install-dispatcher.ps1`: delete the comment and the `AghanimDispatcher` lookup and unregister.
- `docs/install.md`: delete the "Upgrading from Aghanim's Anvil" section.
- `scripts/test/gate-stack.test.sh`: the fake `up` records the names of the `AGHANIM_*` variables it sees instead of the `echo "old ..."`; the old-name assertion becomes "none seen".
- `scripts/test/shipfloor-cli.test.sh`: the "doctor tells … to migrate" case inverts (no warning, directory still there); `migrate-home` exits 2.
- `scripts/test/transition.test.sh`: delete the `migrate-home` cases and `mk_old`; fix the header comment; the "install drops files the plugin no longer ships" case stays, with a neutral stale file name.
- `scripts/test/hygiene.test.sh`: checks for AC-4, AC-5 and AC-7 (below).
- `scripts/test/dashboard.test.sh`: a `/aghanim:` run beside the existing `/mylos:` one.

**Migration plan:** none. Nothing stored changes shape; an existing `~/.aghanim` home or `AghanimDispatcher` task on a machine is left as it is.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/gate-stack.test.sh` |
| AC-2 | factory | `scripts/test/shipfloor-cli.test.sh` |
| AC-3 | factory | `scripts/test/shipfloor-cli.test.sh` |
| AC-4 | factory | `scripts/test/hygiene.test.sh` |
| AC-5 | factory | `scripts/test/hygiene.test.sh` |
| AC-6 | factory | `scripts/test/dashboard.test.sh` |
| AC-7 | factory | `scripts/test/hygiene.test.sh` |

## Security
_Cybersec_ — n/a

## Rollback
Not destructive: revert the commit and the aliases, the command and the docs are back.

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- The upgrade section is removed from `docs/install.md`, not `README.md` as the issue says: #111 moved it there, and `README.md` has no mention left (AC-5 still checks both).
- AC-4 and AC-5 are static checks in `hygiene.test.sh`: running `install-dispatcher.ps1` would register a real scheduled task, and the hygiene test already reads the installer and the docs.
- AC-7 tightens the existing stale-name check: lines marked `legacy aghanim` / `legacy mylos` are accepted only in `scripts/dashboard.py` and `scripts/dashboard_cost.py`, so a new "legacy" bridge cannot slip in.
- `scripts/test/lib.sh` and `scripts/test/demo-stack.sh` keep unsetting inherited `AGHANIM_*` variables: a test started from a run of an older installed factory would otherwise see them and fail AC-1 falsely.
- `transition.test.sh` keeps its "an old `.aghanim/` config dir is not read" case: it guards the no-fallback rule, not a bridge.
- `cmd_install` keeps deleting installed files the plugin no longer ships: it is general upkeep, only its comment named the rename.
- `migrate-home`, the doctor warning, the installer cleanup and the docs section go in this same card, as the issue asks; the cost (a machine never upgraded moves its home by hand) is accepted in Product fit.
- Old specs and plans under `docs/superpowers/` keep their `AGHANIM_*` mentions: they are a record of what was built then.
- This repo's own open branches were checked on 2026-10-12: none reads `AGHANIM_*` in a compose file or an e2e test (the only hits on `origin/main` are the lines this card removes and old specs).
- No UX section and no Cybersec review: no UI is touched and the card has neither label.

## Open questions
- **Other projects' branches:** A (recommended) approve only after the issue's `git grep -l AGHANIM_` over Pickio's open branches comes back empty, or B approve now — the stack of any Pickio card cut before 2026-10-11 fails to come up until `main` is merged into it. This run cannot read other projects' repositories, so the check is the owner's.
