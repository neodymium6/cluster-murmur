# ADR 0048: Insert Immutable Events Idempotently

## Status

Accepted.

## Context

The constrained event record has no runtime store boundary. Event producers may
retry after a local failure and restart, but a retry must neither create a
duplicate fact nor silently replace an event already committed under the same
stable ID.

## Decision

Add one bounded event-store operation that validates and encodes the complete
event before opening an immediate transaction. Attempt an insert without
replacing a primary-key conflict, restore the committed row, and compare every
immutable event field with the encoded candidate.

Return the redacted committed record when the first insert succeeds or an exact
retry finds identical content. Classify reuse of an event ID for different
content as `event_conflict`, invalid input as `invalid_event`, and repository
failures as `storage_unavailable`. Never return input values, database
exceptions, queries, or paths.

Do not add decoded reads, listing, retention, dedupe-window suppression,
trigger execution, or observation-state transactions. Event IDs provide insert
idempotency only; a later transaction must define how a configured dedupe key
and window affect trigger bookkeeping.

## Consequences

Producers can safely retry one immutable event across process failures and
restarts. Conflicting facts cannot overwrite the first committed event. The
operation intentionally does not claim end-to-end exactly-once execution or
replace the separate trigger deduplication policy.
