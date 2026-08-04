# ADR 0054: Persist Constrained Trigger-Execution Records

## Status

Accepted.

## Context

Pure event-trigger plans contain the exact event, execution instant, and next
cooldown projection needed by durable orchestration. Restart-safe deduplication
and cooldown decisions require a constrained record before any store operation
can atomically reserve execution.

## Decision

Add a `trigger_executions` table keyed by the complete trigger ID and immutable
event ID. Store a closed `started`, `completed`, or `failed` status, canonical
UTC execution and cooldown instants, and an optional stable error class. Require
the cooldown deadline to be at or after execution. Only failed records carry a
bounded lowercase error class; started and completed records carry none. Keep a
foreign key to the persisted event and indexes for cooldown and retention-time
queries.

Construct new started records only from an exact, fully redacted pure execution
plan. Revalidate the trigger, event, matcher result, UTC instants, and calculated
cooldown before retaining fields in a changeset. Do not expose a generic
changeset, arbitrary query interface, or terminal transition API.

## Consequences

The schema encodes one bounded lifecycle and one record per trigger/event pair.
A later immediate transaction can insert the started record only when no prior
pair exists and the latest trigger cooldown permits it. Completion and failure
transitions, retry policy, retention cleanup, conversation creation, and action
execution remain later work.
