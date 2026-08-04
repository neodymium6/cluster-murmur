# ADR 0040: Record Stochastic Executions Optimistically

## Status

Accepted.

## Context

Due-schedule discovery is deliberately read-only. After a stochastic action has
completed successfully, its durable next run and daily-limit bucket must advance
together without allowing a stale scheduler view to overwrite newer state.

## Decision

Add one store operation for recording a completed execution. Require the caller
to supply the complete trigger ID, the expected persisted next run, the actual
UTC execution instant, the newly calculated UTC next run, and an optional local
date bucket produced by eligibility policy.

In one immediate transaction, read the schedule and update it only when its next
run equals the expected version and that version was due by the execution
instant. Store the execution instant as the last run, require the new next run
to be later, and either increment the matching local-date bucket, reset a new
bucket to one, or retain no bucket for an unconstrained trigger. Refuse to exceed
the persisted count bound.

Validate all caller-supplied values before storage access and return only stable
classifications and redacted records. Do not execute actions, read a clock,
sample randomness, expose queries, or claim work in this operation.

## Consequences

Successful executions can advance durable state without stale overwrites or
partial counter updates. This is an optimistic post-execution record, not a
claim: two workers could still perform the external action before one observes
a schedule conflict. Claiming, crash recovery, and delivery guarantees require
a separate architecture decision before runtime execution is enabled.
