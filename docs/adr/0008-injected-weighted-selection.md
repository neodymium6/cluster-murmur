# ADR 0008: Use Weighted Deterministic Selection with Injected Randomness

## Status

Accepted.

## Context

Speaker selection must combine affinity, novelty, relationships, and cooldowns
while remaining replayable in tests.

## Decision

Compute non-negative candidate weights in application code and delegate only
the final sample to an injected random behaviour. Include `no_reply` in
responder selection.

## Consequences

Production remains varied while tests and replay use controlled random values.
Weight components and exclusion rules must be observable and well tested.
