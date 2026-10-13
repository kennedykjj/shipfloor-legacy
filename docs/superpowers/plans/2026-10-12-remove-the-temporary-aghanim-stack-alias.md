# Remove the temporary AGHANIM_* stack aliases — plan

**Issue:** #46 · **Spec:** `docs/superpowers/specs/2026-10-12-remove-the-temporary-aghanim-stack-alias-design.md`

Pure removal in one layer, `factory`. QA writes the acceptance tests first; one engineer task then removes the bridges.

## Acceptance tests (QA, before any task)

| AC | File | What the test checks |
|---|---|---|
| AC-1 | `scripts/test/gate-stack.test.sh` | the fake `up` records the names of every `AGHANIM_*` variable it sees; the list is empty, and the `SHIPFLOOR_*` values are still there |
| AC-2 | `scripts/test/shipfloor-cli.test.sh` | `shipfloor migrate-home` exits 2; `shipfloor help` does not list it |
| AC-3 | `scripts/test/shipfloor-cli.test.sh` | with a `~/.aghanim` directory in a fake home, `doctor` prints no warning about it and the directory is still there |
| AC-4 | `scripts/test/hygiene.test.sh` | `installer/install-dispatcher.ps1` has no `AghanimDispatcher` |
| AC-5 | `scripts/test/hygiene.test.sh` | `docs/install.md` and `README.md` have no "Upgrading from Aghanim" section and no `migrate-home` |
| AC-6 | `scripts/test/dashboard.test.sh` | a `/aghanim:` run beside the existing `/mylos:` one is attributed to its stage and card |
| AC-7 | `scripts/test/hygiene.test.sh` | lines marked `legacy aghanim` / `legacy mylos` are accepted only in `scripts/dashboard.py` and `scripts/dashboard_cost.py` |

AC-6 already holds on main (the readers stay): its test passes before and after and guards the removal.

## Tasks

### T1 — remove the bridges
**Layer:** factory · **Owner:** engineer · **Depends on:** the acceptance tests

- `scripts/lib/stack.sh`: delete the two `# legacy aghanim` lines at the end of `slot_env`.
- `scripts/shipfloor`: delete the `migrate-home` header line, `cmd_migrate_home`, its `case` arm and the `~/.aghanim` block in `cmd_doctor`; reword the "drop what the plugin no longer ships" comment in `cmd_install` so it names neither the old name nor `migrate-home` (the cleanup stays).
- `installer/install-dispatcher.ps1`: delete the comment and the `AghanimDispatcher` lookup and unregister.
- `docs/install.md`: delete the "Upgrading from Aghanim's Anvil" section.
- `scripts/test/transition.test.sh` (not an acceptance test): delete the `migrate-home` cases and `mk_old`; fix the header comment; keep the "an old `.aghanim/` config dir is not read" case and the "install drops files the plugin no longer ships" case, the latter with a neutral stale file name.

Left as they are: `RUN_LINE` in `scripts/dashboard.py`, `COMMAND` and `LEGACY_STAGES` in `scripts/dashboard_cost.py`, the `AGHANIM_*` unset in `scripts/test/lib.sh` and `scripts/test/demo-stack.sh`, and everything under `docs/superpowers/`.

**Done when:** the four acceptance test files and `transition.test.sh` pass, and the build gate passes.
