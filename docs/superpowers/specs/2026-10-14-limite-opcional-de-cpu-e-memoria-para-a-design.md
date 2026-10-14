# Optional CPU and memory limit for the factory, configurable in the dashboard — spec

**Issue:** #219 · **Branch:** `feat/219-limite-opcional-de-cpu-e-memoria-para-a` · **Date:** 2026-10-14
**Roles:** PO, Tech Lead, UX/UI
**Weight:** heavy

## Product
_Product Owner_

**Problem:** The factory and everything it starts (agents, builds, tests, stacks) has no ceiling on CPU or memory, so it can slow down the rest of the machine. Whoever installs Shipfloor has no way to choose between no limit and a fixed ceiling.
**Audience:** Developers who install the plugin and run the factory on their own machine (including the factory's owner).
**Acceptance criteria**
- **AC-1** — Given `~/.shipfloor/config.yml` has no `limits` or all values `none`, when `install-dispatcher.sh` runs, then the dispatcher is installed with no CPU or memory limit, the same as today.
- **AC-2** — Given Linux and `limits` with `memory_max`, `cpu_weight` and/or `cpu_quota` set, when `install-dispatcher.sh` runs, then the dispatcher's systemd user unit carries the matching `MemoryMax`/`MemoryHigh`, `CPUWeight` and `CPUQuota`, and runs the dispatcher starts are counted in that unit's cgroup.
- **AC-3** — Given macOS or Windows and any limit set, when `install-dispatcher.sh` runs, then it installs the dispatcher without limits and prints a warning that resource limits are not supported on that OS.
- **AC-4** — Given the dashboard settings, when the owner picks "no limit" or "with limit" with values and saves, then `config.yml` holds the chosen `limits`, the scheduler is re-applied, and reopening the settings shows the saved choice.
- **AC-5** — Given an invalid value (e.g. `cpu_weight` outside 1-10000, unparseable `memory_max` or `cpu_quota`), when the owner saves in the dashboard, then the save is refused with a message naming the field and `config.yml` is unchanged.
- **AC-6** — Given any OS, when `shipfloor doctor` runs, then it shows the limits in effect on the installed dispatcher ("none" when unlimited, "not supported" on macOS/Windows with limits configured).
- **AC-7** — Given Linux with `memory_max` set, when the factory's cgroup memory comes near that ceiling, then the `health-*.jsonl` log gets an entry saying so with the usage and the ceiling.
**Out of scope:** Real limits on macOS and Windows (warning only for now); dispatcher TMPDIR (separate issue); running the factory in a container; per-stage or per-run limits; limits on anything not started by the dispatcher.
**Product fit:** Serves principle 3 (numbers are exact and sourced): doctor reports the limits actually in effect on the unit, not only what the config asks for. It extends the dashboard beyond moving the owner's cards to writing machine config (`config.yml`) and reinstalling the scheduler; this is a new kind of write from the dashboard, still local (127.0.0.1) and owner-only, so it does not contradict the positioning, but the Capabilities list should name it.
**Touches UI:** yes

## UX
_UX/UI Designer_

Screen: Settings › Sessions (`renderSettings`, `SET.sec === "sessions"` in `scripts/dashboard.html`). No new component.

- **Place.** A third `.sgroup.panel` under "Environments": `<h2>` "Machine resources" + `<code>config.yml · limits</code>`, three `row()`s: Memory ceiling (`memory_max`), CPU share (`cpu_weight`), CPU ceiling (`cpu_quota`).
- **Control.** Each row uses the costs text field (`.sknob` > `.cin` input + `<small>` caption, `aria-labelledby`/`aria-describedby` as `costRow`), with no `$` prefix; placeholders `8G`, `100`, `200%`. An empty field means no limit and its caption reads the existing `knob.none` ("no limit"). That is how the owner picks "no limit": all three empty. No radio or switch is added.
- **Draft and save.** Typing is a draft (`limits.<field>` in `SET.draft`, `.dirty` turns it `--sand`), counted by the existing save bar; Save sends `limits: {memory_max, cpu_weight, cpu_quota}` inside the existing `POST /api/settings/machine` body, with empty fields as `null`. Discard restores the saved values.
- **Success (AC-4).** The bar closes and the fields show the saved values in normal text. A filled field's caption reads "in effect" when the installed unit carries that value, and "saved, applies when the dispatcher is reinstalled" (`--warn`) when it does not. No toast.
- **Invalid (AC-5).** A 400 with `errors[].key = limits.<field>` marks that field `.inv` + `aria-invalid`, and its `<small>` carries the server's reason for that field. The draft is kept and `config.yml` is untouched. Other errors use the save bar's existing `.bad` line.
- **Unsupported OS (AC-3).** On macOS and Windows the fields stay editable. One `.note.warn` under the rows: "Resource limits are not supported on this system. They are saved but not applied." It shows only when a value is set.
- **Loading / empty.** Nothing of its own: the panel renders with `/api/settings`, as the other panels do.
- **Small screens.** `.srow` already stacks the text over the `.sknob` below the existing breakpoint. The field keeps the `.cin` width, and no new breakpoint is added.
- **Copy, en → pt-BR** (the other 10 catalogs get the English text until translated):
  - Rows: `Machine resources` → `Recursos da máquina`; `Memory ceiling` / `Most memory the factory and what it starts may use, e.g. 8G. Near it, the health log says so.` → `Teto de memória` / `Máximo de memória que a fábrica e o que ela inicia podem usar, ex. 8G. Perto dele, o log de saúde avisa.`; `CPU share` / `Weight against the rest of the machine, 1 to 10000; 100 is the same as everything else.` → `Fatia de CPU` / `Peso em relação ao resto da máquina, de 1 a 10000; 100 é o mesmo que o resto.`; `CPU ceiling` / `Most CPU time, e.g. 200% for two cores.` → `Teto de CPU` / `Máximo de tempo de CPU, ex. 200% para dois núcleos.`
  - States: `in effect` → `em vigor`; `saved, applies when the dispatcher is reinstalled` → `salvo, vale quando o dispatcher for reinstalado`; `Resource limits are not supported on this system. They are saved but not applied.` → `Limites de recursos não são suportados neste sistema. Ficam salvos, mas não são aplicados.`

## Architecture
_Tech Lead_

One layer: `factory`. No migration; a missing `limits` key means `none` everywhere, so existing configs behave as today.

**Contracts**
- `~/.shipfloor/config.yml` (machine): new optional key `limits: {memory_max: <int><K|M|G|T> | none, cpu_weight: <1-10000> | none, cpu_quota: <int>% | none}` (`cpu_quota` 1%-<cpus×100>%). Distinct from the per-project `limits.refine.wip`.
- `shipfloor_config.py`: `limits_problems(raw) -> [str]` (called from `machine_problems`, each message names the field), `machine_limits(raw) -> dict` (normalized, `none` filled in), `limits_directives(limits) -> [str]` (systemd lines: `MemoryMax=`, `MemoryHigh=` at 90% of max, `CPUWeight=`, `CPUQuota=`). CLI: `shipfloor-config.sh machine limits [--memory-max V] [--cpu-weight V] [--cpu-quota V]` prints the directive lines (overrides on top of the file; exit 2 with the problems on an invalid value).
- `installer/install-dispatcher.sh`: new flags `--memory-max`, `--cpu-weight`, `--cpu-quota` (each also accepts `none`), defaulting to the machine config through `machine limits`. `install_systemd` appends the directives to `[Service]`; the existing `cmp` rewrites and reloads the unit only on change. `cron`/`launchd` kinds with any limit set: install unchanged and print `WARN resource limits are not supported with <kind>; the dispatcher runs without them`. `--status` prints a second line `limits: none` | `limits: memory_max=12G cpu_weight=100 cpu_quota=600%` (read from the installed unit file) | `limits: not supported (<kind>)`.
- `installer/install-dispatcher.ps1`: with any limit in the config, print the same not-supported warning.
- `dashboard.py`: `GET /api/settings` gains `machine.limits: {memory_max, cpu_weight, cpu_quota, in_effect: {same three} | null, supported, why}`; `in_effect` comes from `install-dispatcher.sh --status` (the installed unit), so the UX caption can say "in effect" vs "applies when reinstalled". `POST /api/settings/machine` accepts `{"limits": {memory_max, cpu_weight, cpu_quota}}` (each `null` = no limit). On change, `set_machine` validates (a 400 carries `errors[].key = limits.<field>`), then runs the limits applier first (same "told first; if it refuses, nothing is saved" rule as the pace), then writes `config.yml`. New `limits_applier()` beside `scheduler()`: `SHIPFLOOR_LIMITS_APPLIER` overrides (tests); on Linux `bash <source>/installer/install-dispatcher.sh --memory-max … --cpu-weight … --cpu-quota …`; elsewhere no applier: the values are saved and `supported: false` drives the not-supported note.
- `dashboard.html` + `scripts/lang/dashboard.*.json` (all 12 catalogs; en and pt-BR translated, the rest English): the "Machine resources" panel in ## UX.
- `shipfloor_core/cli.py` `cmd_doctor`: after the dispatcher line, `ok   dispatcher limits: <the --status limits line>`; `WARN` when the config asks for limits the installed unit does not carry (reinstall hint).
- `shipfloor_health.py`: `snapshot()` gains `cgroup: {mem_mb, max_mb}` on Linux when the cycle's own cgroup (`/proc/self/cgroup` → `/sys/fs/cgroup/<path>/memory.current|memory.max`) has a finite `memory.max`, else `null`; at ≥ 90% it appends `memory <mem>/<max> MB` to `over`, so the existing alerts (and `doctor`'s `WARN health:`) pick it up. The cgroup root is overridable by `SHIPFLOOR_CGROUP_ROOT` for tests.

**Files:** `scripts/shipfloor_config.py`, `installer/install-dispatcher.sh`, `installer/install-dispatcher.ps1`, `scripts/dashboard.py`, `scripts/dashboard.html`, `scripts/lang/dashboard.*.json`, `scripts/shipfloor_core/cli.py`, `scripts/shipfloor_health.py`, `PRODUCT.md` (Capabilities line), plus the tests below — all layer `factory`.

## Test plan
_Tech Lead_
<!-- One row per AC: a layer from the config (or manual) and the full repo-relative test file path in backticks, inside that layer's tests. Checked by `gate.sh test-plan`.
     Name the module's existing test file; several ACs share it. A new test file only when no suite covers the module, with the reason in ## Decisions. -->

| AC | Layer | Test file |
|---|---|---|
| AC-1 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-2 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-3 | factory | `scripts/test/install-dispatcher.test.sh` |
| AC-4 | factory | `scripts/test/py/dashboard_settings.py` |
| AC-5 | factory | `scripts/test/py/dashboard_settings.py` |
| AC-6 | factory | `scripts/test/py/cli_doctor.py` |
| AC-7 | factory | `scripts/test/py/health_record.py` |

## Security
_Cybersec_ — n/a

## Rollback
n/a

## Decisions
_What the pipeline decided on its own; one line each, with the reason._
- Limits go on `shipfloor-dispatcher.service`, not the timer: detached runs (`start_new_session`) stay in the service cgroup under `KillMode=process`, so the ceiling covers agents, builds and stacks too.
- `MemoryHigh` = 90% of `MemoryMax`, not a separate knob: throttling before the OOM kill, with no extra field for the owner to understand.
- Health "near the ceiling" = cgroup `memory.current` ≥ 90% of `memory.max`, reported through the existing `over` list: alerts and `doctor` already surface it, no new channel.
- The dashboard applies limits on Linux by rerunning `install-dispatcher.sh` with flags before saving: same "told first, nothing saved on refusal" rule as the pace; today's `scheduler()` is Windows-only, so limits get their own applier.
- Linux with the `cron` scheduler (no systemd user session) is treated like macOS: warn, install without limits — cron has no cgroup to attach them to.
- "No limit" = all three fields empty, no extra switch (UX): matches the cost limits; the issue's "sem limite / com limite" choice is covered.
- `doctor` reads limits from the installed unit via `--status`, not from `config.yml`: it must show what is in effect (principle 3), and warns when the two differ.
- AC-3's Windows half lives in `install-dispatcher.ps1`, which the suite cannot run; it is checked in review, the macOS half by the stubbed `uname` in the existing suite.
- The dashboard already writes `config.yml` (pool, pace, costs); this adds a key, not a new kind of write, so PRODUCT.md gets one Capabilities line only.
- Weight heavy: 7 acceptance criteria and more than 8 files.

## Open questions
- none
