# 0153. Project triggered events deterministically

Date: 2026-08-08

## Status

Accepted. Amended by
[ADR 0231](0231-separate-stochastic-identity-and-occurrence-time.md).

## Context

Schedule and stochastic trigger configuration contains only a bounded event
template. Runtime execution needs a complete immutable event, but deriving its
identity or occurrence time from a retry attempt would allow one durable
schedule version to create multiple conflicting facts.

## Decision

Provide one pure projector for schedule and stochastic templates. Require the
trigger kind, configured trigger ID, exact template, and canonical storage-UTC
scheduled instant. Derive the event ID from the kind, trigger ID, and scheduled
instant, and use that scheduled instant as the event occurrence time. Repeating
the same projection with the exact configured template therefore returns an
identical event.

Do not include the template in the event identity. If configuration changes
while one scheduled version remains durable, the changed template projects
different immutable facts under the same event ID. Idempotent event persistence
then rejects the mismatch as a conflict instead of accepting a duplicate event.
Private assembly must treat that conflict as a failed execution and must not
advance the schedule.

Use a fixed `schedule` or `stochastic` source, `info` severity, empty facts,
and application-owned labels containing only the configured trigger ID and
kind. Derive a stable per-trigger dedupe key without exposing the trigger ID.
Leave observation, state transition, and correlation fields absent. Revalidate
the completed event through the shared bounded event validator.

Do not read a clock, inspect durable schedules, persist the event, complete a
claim, start a conversation, or perform external I/O in this boundary.

## Consequences

Retries with an identical configuration can use idempotent event persistence
without changing immutable event facts. Configuration drift for an outstanding
schedule version fails closed at that persistence boundary. Event-trigger
matchers may route by the configured type, group, subject, or the two fixed
labels, while prompt fact projection continues to exclude labels and trigger
identity.

Execution ordering and atomic correlation between event insertion and schedule
advancement remain separate reviewed runtime work.
