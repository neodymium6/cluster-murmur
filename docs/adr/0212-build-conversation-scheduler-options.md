# 0212. Build production conversation scheduler options

Date: 2026-08-11

## Status

Accepted.

## Context

The production conversation runtime now contains preflighted poll and durable
event-dispatch contexts. The existing schedulers still require exact option
values containing their clock, cycle, storage, cadence, and first-run delay.
Allowing the eventual application entry point to assemble those fields ad hoc
would reopen module selection and could introduce undocumented timing defaults.

Startup deliberately captures one cadence for each scheduler rather than a
separate initial-delay setting. The production projection therefore needs a
deterministic first-run policy derived from that explicit value.

## Decision

Add `ProductionConversationSchedulerOptions.build/1`, accepting only a
validated `Startup.Prepared` value. Build the production conversation runtime,
then create exact `PollScheduler.Options` and
`EventDispatchScheduler.Options` values.

Fix polling to `ObservationIngestionStore` and both workers to `SystemClock`.
Fix durable dispatch to `EventDispatchCycle` and the runtime's fixed dispatch
adapters. Use each scheduler's explicit interval for both `interval_ms` and
`initial_delay_ms`, so the first cycle runs one full cadence after the recovered
worker is started rather than immediately. Pass both option values through the
existing scheduler validators before returning them.

## Consequences

The eventual supervision entry point can start the two conversation schedulers
without selecting modules or inventing delays. A deployment controls the first
run indirectly through the same documented cadence as later runs; changing
that policy would require another reviewed configuration or projection change.

Construction builds and validates values only. It does not schedule a timer,
start a process, read the clock, access SQLite, observe infrastructure, sample
randomness, generate content, or publish.
