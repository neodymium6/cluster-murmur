# 0204. Load bounded scheduler settings

Date: 2026-08-11

## Status

Accepted; amends ADR 0118.

## Context

The recovered runtime requires explicit intervals for poll, event dispatch,
recurring, stochastic, and event-retention schedulers. The standalone entry
point must not invent undocumented live defaults, while accepting arbitrarily
small intervals could create persistence, network, or CPU busy loops.

## Decision

Load all five non-secret intervals from fixed `CLUSTER_MURMUR_*_INTERVAL`
environment variables during startup, after credential-bearing runtime
settings. Parse the established public duration syntax, bound encoded values to
32 bytes, and require every ordinary cycle to be at least one second and event
retention to be at least one minute. Preserve the existing maximum runtime
interval.

Return one exact inspect-safe `SchedulerSettings` value and stable missing or
invalid error classes. Include it in `Startup.Prepared` and revalidate it before
any option construction. Loading does not read a clock, access persistence,
call an external service, or start a worker.

## Consequences

Deployments must explicitly choose all five scheduler cadences. Later runtime
assembly can populate scheduler options without private code or hidden defaults,
and cannot accidentally configure a sub-second busy loop.

These values control only how often bounded cycles are attempted. Per-cycle
work limits, conversation limits, external timeouts, and retention policy remain
owned by their existing independent boundaries.
