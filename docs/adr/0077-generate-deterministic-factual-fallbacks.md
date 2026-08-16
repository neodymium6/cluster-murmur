# ADR 0077: Generate Deterministic Factual Fallbacks

## Status

Accepted. Amended by [ADR 0233](0233-make-generation-conversation-first.md).

## Context

Provider failure or rejected LLM output needs a bounded fallback that consumes
a normal conversation turn without turning arbitrary observation fields,
provider diagnostics, or sensitive identifiers into outbound content.

## Decision

Add a pure fallback generator accepting one exact validated event, bounded
conversation and persona IDs, and an injected generation instant no earlier
than the event's observation or occurrence. Emit one fixed neutral template
that confirms only that an event was recorded. Structural event validation does
not prove semantic correlation between a type and arbitrary previous/current
values, so the fallback must not infer failure or recovery state from the type.

Never interpret or interpolate the event's type, subject, previous/current
values, facts, labels, identifiers, or provider error. Build an unpublished
`fallback` message and pass
the complete result through the shared message validator before returning it.
Do not read a clock, call an LLM, access persistence, publish, or advance a
conversation.

## Consequences

Fallback output is deterministic, factual, and safe under the same boundary as
LLM output, though intentionally less expressive and specific. The orchestrator
must append it through the normal atomic message path so it consumes the same
turn and LLM-call budgets.
