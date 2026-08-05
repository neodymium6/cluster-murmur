# ADR 0080: Project Starter Persona Candidates

## Status

Accepted.

## Context

Starter selection must combine configured persona weights with durable cooldown
facts without allowing malformed runtime values, ambient time, persistence, or
randomness to change eligibility implicitly.

## Decision

Add a pure projector that revalidates one binding, the bounded persona catalog,
the bounded loaded cooldown snapshot, and an injected canonical UTC instant.
Resolve only binding-referenced personas, exclude disabled personas and
cooldowns whose deadline is later than the supplied instant, and retain
eligibility at the exact deadline.

Project candidates in persona-ID order with redacted identity and separate
binding, event-group interest, and spontaneous-weight components. Reject a
combined weight outside the shared finite non-negative boundary. Preserve
zero-weight candidates so the later selector can apply the documented empty
weighted-selection behavior.

Do not sample, read storage or clocks, infer ownership, or apply recent-speaker
policy in this projection.

## Consequences

Eligibility and configured weight calculation are deterministic, bounded, and
replayable. Later selection receives an auditable value without access to
persona prompts or ambient capabilities, while ownership and recent-speaker
components remain explicit future inputs rather than hidden inference.
