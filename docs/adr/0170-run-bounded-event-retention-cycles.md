# 0170. Run bounded event-retention cycles explicitly

Date: 2026-08-09

## Status

Accepted

## Context

The pure retention planner and narrow marker store establish safe calculation
and persistence boundaries, but callers still need one application-owned path
that correlates the normalized configuration, injected time, and store action.
Letting each caller compose those pieces independently could bypass preflight
validation or accept an unbounded or value-bearing result.

## Decision

Add one event-retention cycle that accepts the complete exact startup
configuration, one injected canonical UTC instant, and an exact narrow adapter.
Validate every dependency before deriving the retention plan, then invoke the
marker store exactly once. Accept only a count from zero through 100 and return
that redacted aggregate in an exact result structure.

Map the store's stable availability failure to a stable cycle failure and fail
closed on every other malformed result, exception, exit, or invalid input. Do
not read a clock, repeat batches, schedule cleanup, expose marker values, or
delete immutable event records.

## Consequences

An operator-controlled caller can safely run one bounded cleanup batch with a
known configuration and time. Repetition, lifecycle scheduling, and
event-record retention remain separate follow-up work.
