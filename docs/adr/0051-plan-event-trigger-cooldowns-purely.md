# ADR 0051: Plan Event-Trigger Cooldowns Purely

## Status

Accepted.

## Context

Matching deliberately does not apply cooldown policy. A later durable trigger
transaction needs one deterministic decision for a selected, runtime-validated
event trigger and its optional persisted cooldown deadline.

## Decision

Add a pure cooldown evaluator that accepts a complete event trigger, an optional
persisted UTC cooldown deadline, and an injected current UTC instant. Skip while
the persisted deadline is strictly later than the current instant. At the exact
deadline or after it, return an eligible decision with a newly calculated
deadline using the trigger's bounded cooldown duration and microsecond storage
precision.

Require exact canonical UTC DateTime values in SQLite's supported year range.
Return only stable classifications and a calculated deadline; do not return
trigger IDs, binding IDs, matcher operands, or rejected values. Fail closed when
deadline arithmetic leaves the storage range.

Do not read a clock or repository, write cooldown state, select triggers or
personas, start conversations, execute actions, or define retry semantics.

## Consequences

Cooldown boundary behavior and deadline arithmetic are deterministic and ready
for a later immediate transaction. Persistence must still atomically compare
and update the durable trigger execution state before any runtime action is
enabled.
