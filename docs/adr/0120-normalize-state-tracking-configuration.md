# ADR 0120: Normalize State-Tracking Configuration

## Context

Observation ingestion already consumes a bounded debounce policy, while the
public configuration contract names separate required counts for failures and
successes. Passing decoded maps directly to runtime ingestion would leave field
shape, default behavior, and the failure-to-unhealthy mapping implicit.

## Decision

Define one exact version 1 state-tracking configuration value with bounded
positive `failures_required` and `successes_required` counts. Keep the fixed
default at two for each direction and project the normalized value explicitly
to the ingestion policy's unhealthy and healthy thresholds.

The boundary rejects unknown fields, forged normalized values, non-integers,
zero, and values above the shared safe-integer limit. It performs no observer
call, persistence, or state-transition decision.

## Consequences

Startup configuration can add this value separately without changing the pure
debounce evaluator or atomic ingestion store. Source- and subject-specific
override syntax remains deferred until its public shape and precedence rules
are reviewed.
