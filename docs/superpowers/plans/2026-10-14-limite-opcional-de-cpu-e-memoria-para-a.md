# Plan — #219 Optional CPU and memory limit for the factory

Spec: `docs/superpowers/specs/2026-10-14-limite-opcional-de-cpu-e-memoria-para-a-design.md`
Layer: `factory` (path `./`, agent `engineer`) for every task. Tasks run in order; each depends on the one before.

## Task 1 — machine `limits` in the config (factory)
- `scripts/shipfloor_config.py`: `limits_problems(raw)` (wired into `machine_problems`, every message names the field `limits.<field>`), `machine_limits(raw)` (normalized, `none` filled in), `limits_directives(limits)` (`MemoryMax=`, `MemoryHigh=` at 90% of max, `CPUWeight=`, `CPUQuota=`).
- CLI `shipfloor-config.sh machine limits [--memory-max V] [--cpu-weight V] [--cpu-quota V]`: prints the directive lines, overrides on top of the file, exit 2 with the problems on an invalid value.
- Covers the base of AC-1, AC-2, AC-5.

## Task 2 — installer (factory) — depends on 1
- `installer/install-dispatcher.sh`: flags `--memory-max`, `--cpu-weight`, `--cpu-quota` (each accepts `none`), defaulting to the machine config via `machine limits`; `install_systemd` appends the directives to `[Service]` (the existing `cmp` reloads only on change); `cron`/`launchd` with any limit: install unchanged and `WARN resource limits are not supported with <kind>; the dispatcher runs without them`; `--status` second line `limits: none` | `limits: memory_max=… cpu_weight=… cpu_quota=…` (from the installed unit) | `limits: not supported (<kind>)`.
- `installer/install-dispatcher.ps1`: the same not-supported warning when the config has any limit.
- AC-1, AC-2, AC-3. Tests: `scripts/test/install-dispatcher.test.sh`.

## Task 3 — dashboard (factory) — depends on 1, 2
- `scripts/dashboard.py`: `GET /api/settings` gains `machine.limits {memory_max, cpu_weight, cpu_quota, in_effect, supported, why}`; `POST /api/settings/machine` accepts `limits` (400 with `errors[].key = limits.<field>`), runs `limits_applier()` first (`SHIPFLOOR_LIMITS_APPLIER` override; Linux runs `install-dispatcher.sh` with the flags), then writes `config.yml`.
- `scripts/dashboard.html`: "Machine resources" panel in Settings › Sessions per the spec's ## UX.
- `scripts/lang/dashboard.*.json` (12 catalogs; en and pt-BR translated, the rest English).
- `PRODUCT.md`: one Capabilities line.
- AC-4, AC-5. Tests: `scripts/test/py/dashboard_settings.py`.

## Task 4 — doctor and health (factory) — depends on 2
- `scripts/shipfloor_core/cli.py` `cmd_doctor`: `ok   dispatcher limits: <--status limits line>`; `WARN` with a reinstall hint when the config asks for limits the unit does not carry.
- `scripts/shipfloor_health.py`: `snapshot()` gains `cgroup {mem_mb, max_mb}` from `/proc/self/cgroup` → `<root>/<path>/memory.current|memory.max` (root overridable by `SHIPFLOOR_CGROUP_ROOT`); at ≥ 90% append `memory <mem>/<max> MB` to `over`.
- AC-6, AC-7. Tests: `scripts/test/py/cli_doctor.py`, `scripts/test/py/health_record.py`.
