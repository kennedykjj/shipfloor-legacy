# Plan — #244 shipfloor pool exits 0 when the stack queue is empty

Spec: `docs/superpowers/specs/2026-10-14-shipfloor-pool-sai-com-1-quando-ha-design.md`

## Tasks

1. **factory** · owner: `qa-engineer` · files: `scripts/test/py/cli_registry.py`
   Acceptance tests (AC-1..AC-4): pool exits 0 with an empty queue, with a queued count, with no project; non-zero on invalid config and on a stack-status failure.
2. **factory** · owner: `engineer` · depends on 1 · files: `scripts/shipfloor_core/cli.py`
   `cmd_pool`: no registered project returns 0; `queue 0` no longer sets `right = 1`; result is `right or left`; refresh the stale comment at `use first`.
