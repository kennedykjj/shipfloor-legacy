# Review criteria (Tech Lead)

Default criteria for any stack. A project replaces them with `review_criteria:` in `.aghanim/factory.yml` (e.g. `.aghanim/review-criteria.md`).

Severity: 🔴 blocker (goes back to the owner of the file), 🟡 should-fix (comment on the PR), ⚪ nit (comment on the PR).
Project rules in `CLAUDE.md` also apply; a violation of a CLAUDE.md "never" rule is 🔴.

## Security / personal data
- 🔴 Personal data (name, e-mail, phone, document, tokenized URLs) in logs or in an error response.
- 🔴 Logging a whole request/response payload instead of the ids.
- 🔴 Secret, key or credential in code or config committed to the repo.
- 🟡 External input flowing into a query, path, shell command or storage key without validation and per-tenant isolation.

## Transactions & data
- 🔴 Event, e-mail or notification sent inside the transaction instead of after commit.
- 🔴 Lost update on a shared row without a lock or a conditional update.
- 🟡 Missing or wrong transaction boundary for a use case.
- 🟡 Migration: `NOT NULL` without backfill first; foreign key without explicit name or delete rule; editing an applied migration (🔴).

## Resilience
- 🔴 External call without timeout; retry on a non-transient error.
- 🟡 Async failure swallowed instead of logged.

## Contracts
- 🔴 Changing an existing endpoint path, event schema or response field without keeping the old one.
- 🟡 Request constraint without declarative validation.
- 🟡 Layer boundaries skipped (e.g. a handler talking to storage directly) where the codebase keeps them.

## Code
- 🔴 Money as floating point.
- 🔴 Unsafe casts or forced unwraps where the language offers a checked form.
- ⚪ Deep nesting where an early return or a match reads better; repeated magic string.

## Tests
- 🟡 New branch without a test; test that only checks the happy return value and not the observable effect.
- 🟡 Time-dependent test (sleeps, wall-clock now inside the flow).
- ⚪ Test that only exercises framework wiring.

## Frontend
- 🔴 Hard-coded user-facing string in a project that has i18n.
- 🟡 Component that ignores the design system's tokens or reimplements an existing component.

## Observability
- 🟡 Unstructured log; missing business id in a log about a failure.
- ⚪ Wrong log level (expected events at WARN).
