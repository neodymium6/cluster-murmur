# ADR 0073: List Bounded Persona Message History

## Status

Accepted.

## Context

Later prompt construction needs a small amount of recent persona-specific
context across conversations. Loading unbounded history, accepting malformed
persona identifiers, or treating an unpublished generated message as spoken
context would violate the memory and publication boundaries.

## Decision

Add a read-only message-store operation that accepts one bounded portable
persona ID, a current conversation ID to exclude, and an injected canonical UTC
cutoff. Return at most the latest six messages that are published at read time
and were generated at or before that cutoff, in chronological order, using the
surrogate ID as a deterministic tie-breaker. Apply the conversation exclusion
before the limit so current-conversation context neither duplicates results nor
hides older eligible history. Validate every loaded record and its persona,
publication, cutoff, and timeline correlation before projecting it to a
redacted domain message.

Add a partial composite index over persona, insertion time, and surrogate ID for
published records. Do not load current-conversation history, assemble prompts,
read a clock, or infer that unpublished generation was delivered.

## Consequences

Cross-conversation persona memory is bounded, deterministic for the current
publication state, and excludes undelivered content. Because messages do not
store a publication timestamp, the cutoff bounds generation time rather than
reconstructing historical publication state. Callers must supply the decision
cutoff and current conversation explicitly and combine this result with the
separately bounded current-conversation context.
