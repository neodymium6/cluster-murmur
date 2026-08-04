# ADR 0007: Use Shifted Exponential Stochastic Schedules

## Status

Accepted.

## Context

Spontaneous conversation should feel irregular while retaining a hard minimum
interval, active hours, and a daily limit.

## Decision

Sample the next wait as a configured minimum plus an exponential random delay.
Persist the next run and daily counters and restore them through an injected
clock after restart.

## Consequences

Conversation timing avoids a mechanical fixed cadence without bursts below the
minimum. Sampling and timezone restoration require focused deterministic tests.
