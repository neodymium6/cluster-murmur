# 0213. Build production background scheduler options

Date: 2026-08-11

## Status

Accepted.

## Context

Recurring schedules, stochastic schedules, and event retention already have
bounded non-overlapping scheduler workers and explicit startup cadences. The
standalone application still needs exact production option values without
reopening cycle, clock, or randomness selection in deployment configuration.

## Decision

Add `ProductionBackgroundSchedulerOptions.build/1`, accepting only a validated
`Startup.Prepared` value. Build exact options for
`RecurringScheduleScheduler`, `StochasticScheduler`, and
`EventRetentionScheduler`.

Fix each scheduler to its application-owned cycle and to `SystemClock`. Fix the
stochastic scheduler to `SystemRandom`. Use each explicit cadence for both the
recurring interval and initial delay, matching the conversation scheduler
policy that the first cycle runs one full cadence after worker start. Validate
all three option values before returning an inspect-redacted aggregate.

## Consequences

Later supervision assembly can start all three background schedulers without
caller-selected modules or hidden live timing values. Their cycle modules keep
their existing fixed persistence boundaries; this projection does not add a
generic store interface.

Construction starts no process or timer and does not read a clock, sample
randomness, access SQLite, generate an event, or perform retention.
