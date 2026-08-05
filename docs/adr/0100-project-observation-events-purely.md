# ADR 0100: Project observation events purely

## Status

Accepted

## Context

Debounced entity state must become an immutable event only for the transition
matrix defined by the application. The LLM and observer adapters must not decide
whether a failure or recovery occurred.

## Decision

Compare validated prior and next durable states in a pure projector. Emit
`observation.failed` for initial or healthy-to-unhealthy commits,
`observation.recovered` for unhealthy-to-healthy commits, and no event for every
other valid state. Copy only validated latest facts and labels. Derive stable
event IDs and bounded dedupe keys from confirmed identity, type, and observation
time using SHA-256. Canonical Unix microseconds make equal instants produce the
same ID regardless of `DateTime` precision metadata. The shared entity-state
payload boundary reserves the fixed event metadata budget.

Failures have `warning` severity and recoveries have `info` severity. The
projector performs no persistence, dedupe-window decision, or publication.

## Consequences

Factual event decisions remain deterministic application code. Replays produce
the same immutable event, while event storage and trigger execution remain
separate boundaries.
