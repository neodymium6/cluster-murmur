# ADR 0052: Centralize Storage UTC Validation

## Status

Accepted.

## Context

Events, stochastic schedules, execution plans, and event-trigger cooldowns each
repeat parts of the same persistence datetime boundary. Small differences in
year or forged-struct handling can produce values that validate in one runtime
path but cannot be stored or safely restored by another.

## Decision

Add one storage UTC operation to the shared DateTime validator. Require the
exact DateTime struct shape, ISO calendar, canonical `Etc/UTC` metadata, valid
calendar fields and microseconds, and a year in `0..9999`.

Use this operation for bounded events, stochastic schedule stores, due-state
evaluation, stochastic execution planning and next-run calculation, and event
trigger cooldown planning. Preserve each caller's existing public error class.

Do not read clocks, convert local timezones, access persistence, or change
scheduling and cooldown decisions.

## Consequences

Every value intended for SQLite UTC datetime storage now crosses the same exact
runtime boundary. General timezone-aware evaluation can continue using the
broader canonical DateTime validator where local IANA instants are intentional.
