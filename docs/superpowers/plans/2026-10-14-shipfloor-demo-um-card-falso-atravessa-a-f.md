# Plan — #175 shipfloor demo: a fake card crosses the factory

Spec: `docs/superpowers/specs/2026-10-14-shipfloor-demo-um-card-falso-atravessa-a-f-design.md`
Layers: `factory` only (path `./`, agent `engineer`).

## Tasks

### T0 — Acceptance tests (qa-engineer)
- Files: `scripts/test/demo.test.sh` (new), test stubs under `scripts/test/fixtures/` if needed.
- Covers AC-1..AC-8. Isolation: `HOME` and `SHIPFLOOR_HOME` in temp dirs, sentinel tree hashed before/after, failing `gh` and `claude` on PATH, `--no-dashboard` for the main run; the dashboard check runs once on a free port with the browser opener disabled.
- Depends on: nothing.

### T1 — `shipfloor demo` (factory, engineer)
- Files:
  - `scripts/demo/gh` (new, executable): offline gh stand-in (project items/board moves, issues, labels, comments, PR create/merge), state in a JSON file under the demo's temp home.
  - `scripts/demo/` sample project and recorded transcripts (spec text, code change, run logs), or generated inline by `demo.py` — engineer's choice, all under `scripts/demo/` or `scripts/shipfloor_core/`.
  - `scripts/shipfloor_core/demo.py` (new): `main(args)`; temp home, local bare origin + clone of the sample project with `.shipfloor/factory.yml`, register via `cli.cmd_add`, play refine → develop → validate → deploy with real `board.sh`, `gate.sh` red/green, git commits, `report.sh`; one block to the owner, two owner approvals; narration lines; banner stating no LLM ran; `--no-dashboard`, `--keep`; cleanup on success, error and Ctrl+C.
  - `scripts/shipfloor_core/cli.py`: `COMMANDS["demo"]`, `usage()`.
  - `scripts/shipfloor`: header lists `demo`.
  - `README.md`: "Try it: `shipfloor demo`" section before "Quick start".
  - `docs/install.md`: one sentence about the demo.
- Depends on: T0.
- Done when: every `scripts/test/demo.test.sh` check passes and the `build` gate is green.

## Order
T0 → T1.
