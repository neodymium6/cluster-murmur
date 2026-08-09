# 0178. Plan claimed recurring executions purely

Date: 2026-08-09

## Status

Accepted

## Context

The recurring schedule store can grant one exact due version an opaque lease,
but a claim alone must not permit unvalidated trigger facts or arbitrary next
state to cross the eventual commit boundary.

## Decision

Add a pure planner that accepts one exact validated recurring trigger, claim-free
durable due projection, opaque fixed-duration claim, and injected canonical UTC
execution instant. Require complete trigger/state/claim correlation and
`next run <= claim start <= execution instant < claim expiry`.

Calculate the next cron run strictly after the execution instant so delayed
workers do not replay every missed wall-clock occurrence. Return a fully
redacted plan containing only the exact claim, application-supplied emitted-event
facts, execution instant, and calculated next run.

Do not read storage or a clock, mutate state, emit an event, execute an action,
renew a lease, or decide delivery behavior.

## Consequences

The later commit boundary can consume a small correlated factual plan without
delegating event or scheduling decisions to an LLM. A subsequent change must
atomically verify the live claim, persist the emitted event handoff, and advance
the recurring schedule before any runtime cycle is enabled.
