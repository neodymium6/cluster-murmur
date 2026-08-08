# 0157. Persist the event dispatch outbox

Date: 2026-08-08

## Status

Accepted

## Context

Stochastic cycles can commit immutable events durably, but immediately handing
the returned event to conversation orchestration would leave a crash window
between event commit and dispatch. Repeatedly scanning the event table is also
not viable: already handled early events would permanently hide later work in
a bounded read.

## Decision

Add a dedicated event dispatch outbox keyed by immutable event ID. Enqueue only
an exact event already present in the event store and preserve its first exact
enqueue instant idempotently. Return only a claim-free receipt, including on a
retry of an entry another worker has already claimed. Keep pending, claimed,
and completed lifecycle states under database constraints.

List no more than 100 pending or expired-claim entries in deterministic
`(enqueued_at, event_id)` order. Return a redacted candidate projection without
claim data. Claim one exact candidate with a random 32-byte capability and a
fixed 60-second lease. Complete only the exact live capability through a
compare-and-set transition, clearing claim material from the terminal row.

Keep the store limited to persistence. Do not select event triggers, start a
conversation, invoke a provider, publish, or expose a generic queue API.

## Consequences

A later bounded worker can safely retry after a crash or expired lease without
letting old completed entries block new work. Concurrent workers cannot both
complete the same claim, and listing never exposes opaque claim material.

Enqueuing stochastic events in the same transaction as event and schedule
commit, plus consuming claimed entries through the existing event-trigger
pipeline, remain separate reviewed changes.
