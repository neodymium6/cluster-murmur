# ADR 0055: Start Trigger Executions Atomically

## Status

Accepted.

## Context

A validated event-trigger plan is still only a projection. Before any runtime
action may use it, durable state must prove that the immutable event exists,
that this trigger/event pair has not run, and that no newer committed cooldown
blocks it. Separate reads and writes would allow concurrent starts to disagree.

## Decision

Add one narrow store operation that first rejects malformed plans without
storage access, then uses the repository's immediate transaction mode to:

1. restore the referenced event through the bounded event store and require it
   to be exactly identical to the plan's event;
2. reject an existing record for the complete trigger/event pair;
3. compare the greatest committed cooldown deadline for that trigger with the
   supplied execution instant, skipping while it is strictly later; and
4. insert the validated started record.

Return stable, value-free conflict, skip, validation, and storage errors. Treat
SQLite constraint exceptions that remain after the transaction's checks as
storage failures. Do not expose generic queries, read a clock, update terminal
status, retry failed work, start a conversation, invoke an LLM, or publish
externally.

## Consequences

Only one writer can authorize a trigger/event pair, and every event rechecks the
latest durable cooldown at the exact boundary that records its start. The
started record is committed before later orchestration performs an action, so
restart recovery can eventually classify incomplete work. Completion/failure
transitions and recovery policy remain separate decisions.
