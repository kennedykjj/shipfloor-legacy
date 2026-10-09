# Review criteria (Tech Lead)

Severity: 🔴 blocker (goes back to the owner of the file), 🟡 should-fix (comment on the PR), ⚪ nit (comment on the PR).
Project rules in `CLAUDE.md` also apply; a violation of a CLAUDE.md "never" rule is 🔴.

## Security / personal data
- 🔴 Personal data (name, e-mail, phone, document, photo URLs with tokens) in logs or in an error response.
- 🔴 Logging a whole request/response payload instead of the ids.
- 🟡 Data class with a sensitive field and the generated `toString()`.
- 🟡 External input flowing into a query, path or storage key without validation and per-photographer isolation.

## Transactions & data
- 🔴 Event, e-mail or notification sent inside the transaction instead of after commit.
- 🔴 Lost update on a shared row without a lock.
- 🟡 Missing or wrong `@Transactional` boundary for a use case.
- 🟡 Conditional update that treats `updated = 0` as an error instead of a no-op.
- 🟡 Migration: `NOT NULL` without backfill first; FK without explicit name or `ON DELETE`; editing an applied migration (🔴).

## Resilience
- 🔴 External call (R2, Resend, Google, Asaas) without timeout; retry on a non-transient error.
- 🟡 Async failure swallowed instead of logged.

## API & contract
- 🔴 Changing an existing endpoint path or response field without keeping the old one.
- 🟡 Controller calling a repository directly or returning an entity instead of a `*Response`.
- 🟡 Request constraint without declarative validation.

## Kotlin
- 🔴 Money as floating point.
- 🔴 `!!` or `as T` (CLAUDE.md safety conventions).
- ⚪ Nested if-else pyramid where `when` reads better; repeated magic string.

## Tests
- 🟡 New branch without a test; test that only checks the happy return value and not the observable effect.
- 🟡 Time-dependent test (`Thread.sleep`, `now()` inside the flow).
- ⚪ Test that only exercises framework wiring.

## Frontend
- 🔴 Hard-coded user-facing string (i18n pt-BR, en, es is mandatory).
- 🟡 Client gallery screen that needs explanation to use on a phone (PRODUCT.md principle 2).
- 🟡 Component that ignores DESIGN.md tokens.

## Observability
- 🟡 Unstructured log; missing business id (sessionId, photographerId) in a log about a failure.
- ⚪ Wrong log level (expected events at WARN).
