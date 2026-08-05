# ADR 0064: Finish Conversations Once

## Status

Accepted.

## Context

Conversation completion, cancellation, and failure can race with one another or
arrive again after a timeout. A read followed by an unconditional update could
overwrite the first terminal outcome or allow a forged stale runtime value to
mutate current counters and status.

## Decision

Add three narrow terminal operations backed by one exact compare-and-set.
Require an exact loaded active record, an explicit canonical UTC completion
instant at or after its start, and equality of the durable root event, active
status, counters, start instant, and absent completion instant. Update only
status and completion time, then restore and validate the terminal record.

The application supplies the factual terminal decision. The store does not ask
an LLM, advance counters, publish, retry, or choose a terminal reason.

## Consequences

Only the first completion, cancellation, or failure wins. Repeated, stale, and
terminal capabilities fail without changing durable state. Completion time is
normalized by the storage type and returned only through a redacted record.
