# 0179. Complete recurring schedule claims atomically

Date: 2026-08-09

## Status

Accepted

## Context

A pure recurring execution plan calculates factual next state, but durable state
must advance only for the exact live claim that authorized the work. Stale,
expired, replaced, or replayed claims must not overwrite a newer schedule.

## Decision

Extend the fixed recurring schedule store with one completion operation. Accept
an exact opaque claim plus injected execution, record, and next-run UTC instants.
Require the fixed 60-second lease and
`expected run <= claim start <= execution <= record < expiry`, with the next run
strictly after execution.

In one immediate transaction, compare the trigger ID, expected next-run version,
token, claim start, and claim expiry. Update exactly one matching row, recording
the execution, advancing the next run, and clearing all claim fields together.
Validate the restored completed row before returning it.

Do not execute an action, insert an event, read a clock, release a claim early,
renew a lease, or expose repository access.

## Consequences

Only the current live capability can advance recurring state, and retrying a
completed or replaced claim fails closed. Event insertion and dispatch handoff
are not yet atomic with this state update; the next commit boundary must compose
them in one outer transaction before the runtime cycle is enabled.
