# ADR 0034: Evaluate Active Hours in Local Time

## Status

Accepted.

## Context

Stochastic triggers may constrain execution to a daily wall-clock window in an
IANA timezone. The eligibility decision must be deterministic from a supplied
instant and must define boundaries and midnight behavior before scheduler
orchestration is added.

## Decision

Evaluate active hours in their configured embedded-IANA timezone. Treat the
start minute as inclusive and the end minute as exclusive. When start precedes
end, accept times within that daytime interval. When start follows end, accept
times on either side of local midnight. Both instants of a repeated DST wall
time receive the same active-hours decision.

Treat an omitted window as unrestricted. Validate normalized minute offsets,
timezone, and supplied datetime metadata before evaluation, returning stable
errors for forged values. Do not read a clock, inspect daily counters, sample a
wait, persist state, or execute an action.

## Consequences

Active-window policy is replayable and independent from scheduler processes.
Daily-limit attribution, durable next runs, and trigger execution remain later
work.
