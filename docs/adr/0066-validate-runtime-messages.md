# ADR 0066: Validate Runtime Messages

## Status

Accepted. Amended by [ADR 0229](0229-treat-generated-text-as-inert-content.md).

## Context

Conversation state previously exposed an untyped message list. Persisting or
prompting from arbitrary terms would bypass content-size, output-safety,
identifier, timestamp, and inspection-redaction boundaries.

## Decision

Add a redacted typed message value and one fail-closed validator. Require exact
shape, portable conversation and persona IDs, a closed `llm` or `fallback`
origin, nonblank valid UTF-8 content with a 16 KiB hard bound, an optional
bounded decimal Discord message ID, and canonical UTC insertion time. Reject
control characters other than newline, URL forms, and Discord user, role, and
broadcast mention forms.

Allow conversation runtime projections to contain at most 12 individually
validated typed messages from that conversation's participants, in ordered
conversation time, ending at its last-message instant. Require turn and LLM-call
counters to cover the projected messages; an empty projection has no
last-message instant. A configured publication character limit and speaker-name
normalization may impose stricter contextual policy later.

## Consequences

Arbitrary provider output cannot enter conversation state through this domain
boundary, and default inspection reveals only the coarse message origin. The
validator does not invoke a provider, select a persona, publish to Discord, or
assert that supplied content is factually grounded.
