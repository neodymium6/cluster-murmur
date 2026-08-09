# 0180. Commit recurring events atomically

Date: 2026-08-09

## Status

Accepted

## Context

Recurring planning and schedule completion are individually bounded, but
committing an event separately from state advancement can leave a crash-created
partial result. The dispatch handoff must also share the same outcome.

## Decision

Add a fixed commit store that accepts one exact redacted recurring execution
plan, its deterministically projected immutable event, and an injected record
instant. Re-project the expected event from application-owned trigger facts and
the scheduled version before storage access.

In one immediate outer transaction, insert or restore the immutable event,
enqueue or restore its pending dispatch handoff, and complete the exact live
schedule claim. Treat changed event facts, changed dispatch enqueue time, stale
claims, and non-pending handoffs as conflicts. Roll back every newly inserted or
updated row when any step fails.

Do not execute actions, dispatch events, read clocks, calculate recurrence,
perform provider I/O, or expose generic repository operations.

## Consequences

A successful commit durably advances all three internal records together, and
safe identical event/outbox retries can finish a still-live claim. External
delivery remains a separate bounded outbox consumer. A later runtime cycle must
validate and correlate batches before taking claims.
