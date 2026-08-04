# ADR 0031: Validate Bounded Stochastic Triggers

## Status

Accepted.

## Context

Version 1 documents a shifted-exponential trigger for ambient conversations,
but the configuration boundary rejects it. Accepting timing inputs without
semantic bounds could produce a non-positive exponential delay, ambiguous
active windows, or impractical scheduler state. Configuration parsing must not
sample randomness or mutate durable state.

## Decision

Accept `shifted_exponential` stochastic triggers in the shared 256-trigger ID
namespace. Require positive mean and minimum intervals no greater than 365 days,
with the mean strictly greater than the minimum. The later sampler will use the
difference as the exponential component's mean.

Allow optional active hours with distinct strict `HH:MM` endpoints and an IANA
timezone from the embedded snapshot. Windows may cross midnight. Allow an
optional daily limit from 1 through 10,000 only when active hours supply an
explicit timezone for its daily reset. Require the same bounded `emit_event`
action as schedule triggers and resolve its group during complete configuration
assembly. Normalize all values into redacted domain structs.

Do not sample randomness, calculate or persist next runs, update daily counters,
or emit events during validation.

## Consequences

All documented version 1 trigger variants now have closed configuration
boundaries. Invalid stochastic schedules fail before external connections, and
later runtime work receives normalized milliseconds and minute-of-day values.
Sampling, durable scheduling, and execution remain separate future work.
