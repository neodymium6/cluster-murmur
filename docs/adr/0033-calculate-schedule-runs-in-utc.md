# ADR 0033: Calculate Schedule Runs in UTC

## Status

Accepted.

## Context

Validated schedule triggers contain local cron expressions and IANA timezones.
Runtime orchestration needs a deterministic next instant across daylight-saving
gaps and folds without coupling the calculation to a clock, executor, or store.

## Decision

Calculate the first matching instant strictly after a supplied `DateTime` and
return it in UTC. Evaluate cron fields in the trigger's embedded-IANA timezone.
Skip nonexistent wall times during a forward DST transition. During a backward
transition, use only the earlier occurrence of an ambiguous wall time so one
cron occurrence cannot execute twice.

Bound dependency search work, reject forged trigger and datetime values, and
collapse dependency errors and exceptions into stable application errors. Do
not read a clock, execute actions, or persist next-run state in this pure
boundary.

## Consequences

Schedule calculation is replayable from a trigger and supplied instant, and
persisted callers can store an unambiguous UTC result. Clock injection,
durability, missed-run policy, and action execution remain later work.
