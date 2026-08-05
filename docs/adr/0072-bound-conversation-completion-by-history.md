# ADR 0072: Bound Conversation Completion by Message History

## Status

Accepted.

## Context

Conversation history reads reject a terminal record whose completion instant is
earlier than its latest committed message. Rejecting only at read time still
allows an internally inconsistent terminal record to be committed.

## Decision

Before completing, cancelling, or failing an exact active conversation, load
its bounded validated history through the narrow message store and require the
terminal instant to be at or after the latest committed message. Propagate
stale-capability and invalid-record failures without committing a transition.

The subsequent terminal compare-and-set still checks every mutable conversation
field. An append racing after the history read changes the durable counters, so
the terminal transition loses the compare-and-set instead of committing an
instant before that message.

## Consequences

New terminal records cannot end before committed message history, while legacy
or externally corrupted records continue to fail closed on history reads. The
transition now depends on the constrained message-history store and therefore
requires the messages migration to be present before runtime use.
