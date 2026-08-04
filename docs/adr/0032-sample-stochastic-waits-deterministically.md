# ADR 0032: Sample Stochastic Waits Deterministically

## Status

Accepted.

## Context

Validated stochastic triggers define a minimum interval and a larger total mean
interval. Runtime scheduling needs a replayable calculation without delegating
policy or parameter validation to a random adapter.

## Decision

Use one injected uniform sample in the half-open interval `[0.0, 1.0)` and the
exponential inverse CDF. Subtract the minimum interval from the configured mean
to obtain the exponential component's mean, truncate that sampled component to
whole milliseconds, and add the minimum interval.

Reject forged trigger values, invalid adapters, non-float samples, non-finite
values, and values outside the half-open interval with stable errors. Collapse
adapter exceptions without exposing their contents. Do not inspect active
hours, daily limits, persistence, or clocks during this pure calculation.

## Consequences

The same trigger and uniform sample always produce the same wait, and no sample
falls below the configured minimum. Scheduler state and next-run persistence
remain separate future work.
