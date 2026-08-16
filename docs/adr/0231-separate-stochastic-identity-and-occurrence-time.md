# ADR 0231: Separate Stochastic Identity and Occurrence Time

## Status

Accepted. Amends
[ADR 0153](0153-project-triggered-events-deterministically.md).

## Context

Stochastic event identity and `occurred_at` were both derived from the durable
sampled `next_run_at`. This made retries idempotent, but a schedule delayed by
active-hours gating or downtime exposed the expired deadline as the event's
actual occurrence time. Presentation timezone conversion correctly rendered
the wrong instant and made the delay visible in generated dialogue.

## Decision

Continue deriving a stochastic event ID from the trigger ID and durable sampled
schedule instant. Derive `occurred_at` from the validated execution instant in
the claimed execution plan. Require the occurrence instant to be equal to or
later than the scheduled instant.

Reconstruct both values at the atomic commit boundary. Event insertion,
dispatch enqueue, and schedule advancement remain one transaction. A failed
transaction leaves no partial event, while concurrent or repeated attempts use
the same event ID and cannot create duplicates. A conflicting occurrence or
template for an already committed schedule version fails closed.

Recurring schedule events retain their existing behavior: the scheduled
instant is both their identity version and occurrence time.

## Consequences

Delayed stochastic events report when execution actually began while retaining
stable retry and deduplication identity. The internal sampled deadline remains
available in the schedule and claim records but is not presented as event
occurrence time.

This decision does not determine how active-hours-ineligible schedules advance;
that scheduling policy is addressed separately.
