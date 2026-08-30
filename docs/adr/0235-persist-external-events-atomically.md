# ADR 0235: Persist External Events Atomically

## Status

Accepted. Extends
[ADR 0234](0234-define-normalized-external-event-ingestion.md) and reuses the
outbox from [ADR 0157](0157-persist-event-dispatch-outbox.md).

## Context

A normalized external event can be retried after a caller loses the response.
Persisting the event and its dispatch handoff separately would create a crash
window, while accepting a caller-selected event ID would widen the capability
defined by ADR 0234.

## Decision

Derive the immutable event ID and deduplication key from the configured source
and supplied idempotency key with a domain prefix and SHA-256. The application,
not the caller, owns this durable identity. Copy only validated envelope facts
into the event; do not add an observation state or acceptance time to the
immutable content.

Commit the event and existing event-dispatch outbox row in one immediate
database transaction. An exact retry restores the original event and the
current claim-free dispatch receipt, including after the dispatch completes.
The same identity with changed content, or an event without its corresponding
dispatch row, is a stable conflict and is never repaired implicitly.

Keep dispatch claiming, trigger selection, conversation orchestration, HTTP,
authentication, and publication outside this transaction.

## Consequences

An acknowledged commit has one durable event and one durable handoff. Ambiguous
retries cannot create a second conversation, change the first enqueue time, or
overwrite facts. The new boundary reuses existing tables and migrations.

External events are still not network reachable. A later reviewed transport
must validate and authenticate a bounded request before calling this store.
