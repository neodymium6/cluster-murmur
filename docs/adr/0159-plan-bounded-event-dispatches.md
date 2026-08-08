# 0159. Plan bounded event dispatches

Date: 2026-08-08

## Status

Accepted

## Context

The durable event-dispatch outbox exposes at most 100 available candidates and
the event store can restore each immutable event. Claiming entries before the
complete batch is correlated with current event triggers could partially mutate
work that later proves malformed or unbounded.

## Decision

Add a pure batch planner that positionally correlates each claim-free candidate
with one restored event in strict `(enqueued_at, event_id)` order. Revalidate
the complete current configuration, candidate and event shapes, enqueue and
execution times, and the first enqueue instant relative to the event facts.

Keep unmatched events as explicit entries so a later consumer can close their
handoffs. Select matching event triggers in stable ID order and reject more
than 100 candidates or more than 256 aggregate matches before any claim or
trigger authorization occurs. Rebuild plans against the supplied durable facts
and current configuration before consumption.

Do not claim an outbox entry, authorize a trigger, start a conversation, call a
provider, publish, or expose event details through inspection.

## Consequences

A later runtime can preflight the whole available batch before its first
mutation and can process unmatched handoffs without rescanning the event table.
Configuration drift invalidates an old plan rather than dispatching stale
trigger policy.

Claiming, consuming the existing authorized-conversation pipeline, and
completing terminal outbox entries remain separate reviewed work.
