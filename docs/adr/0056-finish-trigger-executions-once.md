# ADR 0056: Finish Trigger Executions Once

## Status

Accepted.

## Context

An atomically started trigger execution records durable authorization before
runtime orchestration acts. That started record needs a bounded terminal result
without allowing stale, forged, or repeated callers to rewrite history.

## Decision

Use the exact redacted started record returned by the store as the completion
capability. Validate its complete schema shape, loaded metadata, portable IDs,
canonical UTC instants, and unchanged started state before storage access.

Provide two compare-and-set transitions: `started` to `completed` with no error
class, and `started` to `failed` with one stable lowercase error class of at most
128 bytes. Match every immutable record field in the update predicate and
restore the terminal record in the same immediate transaction. A missing,
changed, or already-terminal row is a stable execution conflict.

Do not change execution time or cooldown, reopen terminal work, retry actions,
store raw exceptions, read a clock, create conversations, invoke an LLM, or
publish externally.

## Consequences

Exactly one terminal result wins for each started record, including concurrent
completion and failure attempts. Cooldown policy remains based on the committed
start and therefore does not change according to action outcome. Recovery of
records left in `started`, retention cleanup, and runtime action orchestration
remain later decisions.
