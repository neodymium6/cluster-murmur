# ADR 0044: Calculate Stochastic Runs From Sampled Waits

## Status

Accepted.

## Context

Validated stochastic triggers can produce deterministic waits through an
injected random source. Runtime scheduling also needs a replayable boundary
that turns one sampled wait into the next durable UTC instant without coupling
the calculation to a clock or store.

## Decision

Calculate the next run by adding exactly one sampled whole-millisecond wait to
a supplied canonical UTC `DateTime`. Validate the base instant before sampling,
delegate trigger and random-source validation to the existing stochastic
sampler, and preserve its stable value-free errors. Return the resulting UTC
instant, which is strictly after the base because validated minimum intervals
are positive. Require the base and result to use the persistence-supported year
range from 0 through 9999, and return `:no_next_run` when a valid sample would
cross that upper bound.

Do not read a clock, inspect active hours or daily limits, access scheduler
state, claim or mutate a schedule, persist the result, or execute an action in
this pure boundary.

## Consequences

Initialization and post-execution orchestration can calculate the same next run
from the same trigger, base instant, and injected random source. Choosing the
base instant, storing the result, and deciding whether an eligible due schedule
may execute remain separate responsibilities. The stable exhaustion result
prevents callers from receiving a next run that the durable schedule cannot
represent.
