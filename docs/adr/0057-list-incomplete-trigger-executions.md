# ADR 0057: List Incomplete Trigger Executions Boundedly

## Status

Accepted.

## Context

The store commits `started` before runtime action and records terminal outcome
afterward. A process or host failure can therefore leave durable started rows.
Recovery policy first needs a safe observation boundary that cannot load an
unbounded history or silently decide whether work ran.

## Decision

Add a read-only store operation accepting one supplied canonical UTC cutoff.
Return only rows still in `started` whose execution instant is at or before the
cutoff. Order by execution instant, trigger ID, and event ID, and return at most
100 fully redacted records.

Reject malformed cutoffs before storage access and return only stable,
value-free errors. Do not read a clock, mutate or retry executions, infer action
outcome, alter cooldowns, load event facts, create conversations, invoke an LLM,
or publish externally.

## Consequences

Restart orchestration can inspect a deterministic bounded batch without making
an unsafe execution decision. Choosing a grace interval, classifying abandoned
work, pagination, and any retry policy remain separate decisions. Repeated
reads are harmless and terminal rows disappear from later results.
