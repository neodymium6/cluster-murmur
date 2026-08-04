# ADR 0049: Restore Bounded Events by ID

## Status

Accepted.

## Context

The event store can insert immutable records idempotently, but later restart and
transaction work needs a narrow way to restore one domain event without
exposing generic database queries or trusting persisted JSON as domain-valid.

## Decision

Add a primary-key fetch operation that accepts only an event ID satisfying the
same required-string boundary as a complete event. Read at most one constrained
record and reject an encoded payload above the existing 512 KiB database bound.
Decode its four JSON fields with OTP callbacks that stop before exceeding the
domain depth, per-collection entry, node, string, key, numeric, and aggregate
text budgets. Preserve SQL NULL as the only canonical top-level nil encoding,
map nested JSON nulls back to domain nil values, rebuild the exact event shape,
and pass the result through the shared bounded validator.

Return only the redacted event or stable `invalid_event_id`, `event_not_found`,
`invalid_event_record`, and `storage_unavailable` classifications. Treat a row
that SQLite accepts but the tighter application domain rejects as an invalid
record. Do not return encoded records, decoder exceptions, queries, paths, or
input values from this read operation.

Do not add event listing, filtering, deletion, retention, dedupe-window policy,
trigger bookkeeping, or event execution.

## Consequences

Later bounded workflows can restore one persisted event without bypassing the
same domain limits used before matching and insertion. Database constraints
remain defense in depth rather than the authority for application event shape.
Corrupt or out-of-domain rows fail closed and do not partially expose payloads.
