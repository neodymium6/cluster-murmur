# 0156. Schedule stochastic cycles explicitly

Date: 2026-08-08

## Status

Accepted

## Context

The bounded stochastic cycle can durably commit due configured events, but no
runtime worker invokes it repeatedly. A timer must not overlap cycles, conceal
configuration or event data in status, or silently introduce live defaults and
external behavior into the public application.

## Decision

Provide one opt-in `StochasticScheduler` GenServer. Require an exact complete
configuration, narrow cycle, UTC clock, random source, positive interval, and
bounded initial delay before starting. Run each cycle synchronously and create
the next timer only after it returns. Bind timer messages to opaque references
so stray or stale messages cannot start work.

Keep aggregate cycle count, one exact bounded and arithmetically correlated
cycle result, and one stable error class in memory. Redact the nested result and
all configured dependencies from inspection. Convert invalid clock values,
malformed cycle results, exceptions, and exits into the same stable failure
status while keeping later cycles eligible to run.

Do not install the worker in the public application supervision tree or add
deployment defaults. Do not dispatch committed events, generate text, publish,
or perform any new external I/O.

## Consequences

An operator can explicitly supervise non-overlapping stochastic scheduling with
reviewed configuration and dependencies. A slow cycle delays its next run
rather than accumulating concurrent work. Durable claim leases and event
identity continue to protect retries after failures.

Startup composition and crash-safe dispatch of committed stochastic events
remain separate reviewed work.
