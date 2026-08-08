# 0158. Enqueue stochastic events atomically

Date: 2026-08-08

## Status

Accepted

## Context

Stochastic execution already commits its immutable event and claimed next-run
state together, and the event-dispatch outbox provides a durable handoff to
later conversation orchestration. Enqueuing only after that commit would leave
a crash window in which the schedule advanced but no consumer could discover
the event.

## Decision

Extend the fixed stochastic commit transaction to insert the exact projected
event, enqueue its claim-free dispatch receipt at the recording instant, and
advance the exact claimed schedule. Require the returned pending receipt to
correlate with the event ID and recording instant before a stochastic cycle
counts execution.

Preserve exact idempotency for an identical precommitted event and outbox row.
Treat changed event facts, a different first enqueue instant, a non-pending
outbox state, or a schedule compare-and-set failure as a commit conflict and
roll back every mutation made by the attempt.

Keep claiming and consuming outbox entries outside this transaction. Do not
select event triggers, invoke a provider, publish, or perform external I/O.

## Consequences

A successful stochastic commit proves that the event, durable dispatch
handoff, and next schedule state became visible together. A retry cannot change
the first enqueue instant or reuse a handoff that another worker has already
claimed or completed.

Bounded consumption through the existing event-trigger conversation pipeline
remains separate reviewed work.
