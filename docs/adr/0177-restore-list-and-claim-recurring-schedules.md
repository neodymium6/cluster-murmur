# 0177. Restore, list, and claim recurring schedules

Date: 2026-08-09

## Status

Accepted

## Context

Recurring schedule state is durable but inert. A later execution cycle needs a
narrow way to initialize calculated state, discover bounded due work, and gain
exclusive authority before starting an action.

## Decision

Add a fixed store that restores an existing schedule or inserts one supplied
initial run without replacing durable state. List at most 100 due schedules in
`(next_run_at, trigger_id)` order, with cursor pagination and no claim material.

Claim only one exact due version in an immediate transaction when it has no live
claim. Generate an opaque 256-bit token in application code and use a fixed
60-second lease. An expired claim is replaceable at its expiry instant. Keep
clock reads, recurrence calculation, action execution, event emission, claim
completion, caller-selected queries, and caller-selected lease parameters out
of this store.

Validate all inputs before storage access and validate loaded state before
returning it. Collapse storage and malformed-row failures without exposing
schedule identifiers, timestamps, claim values, queries, or database details.

## Consequences

Runtime code can restore and enumerate deterministic cron state without reusing
stochastic policy, and only one live capability can authorize work for a due
version. A later change must define pure execution planning and atomic claim
completion before actions are run.
