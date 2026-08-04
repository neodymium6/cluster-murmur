# ADR 0039: List Due Stochastic Schedules Without Claiming

## Status

Accepted; amended by ADR 0042.

ADR 0042 keeps this operation read-only but excludes schedules with live claims
and omits claim fields from the returned projection.

## Context

Restored stochastic schedules need bounded discovery before a scheduler can
decide which work is due. Combining discovery with claiming or advancement
would prematurely choose crash and delivery semantics.

## Decision

Add a read-only store operation that accepts one structurally valid UTC instant
and returns schedules whose persisted next run is at or before it. Order by next
run and then complete trigger ID so repeated reads are deterministic. Return at
most 100 redacted schedule records per call; do not expose caller-selected
limits, offsets, filters, or arbitrary queries.

Validate the supplied instant before accessing storage and classify failures
without returning query text, database details, schedule values, or the rejected
instant. This operation does not read a clock itself.

Do not claim, lease, update, sample, emit, or authorize execution. A returned
schedule is only a due-state observation and may appear again on the next read.

## Consequences

The scheduler can inspect a bounded deterministic due set while clock injection
and mutation semantics remain explicit. Callers must not treat discovery as an
exclusive claim. A later transactional operation must prevent duplicate work
when advancing a schedule.
