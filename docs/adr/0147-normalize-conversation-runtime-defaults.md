# ADR 0147: Normalize Conversation Runtime Defaults

## Status

Accepted.

## Context

Bounded responder orchestration requires an immutable budget, continuity
policy, and no-reply weight. These values are documented as version 1
configuration defaults but were not represented in the parsed manifest or
complete runtime configuration, forcing callers to manufacture policy.

## Decision

Add an optional exact `conversation_defaults` manifest mapping. When omitted,
normalize the documented version 1 values: three turns, two participants, five
minutes, three LLM calls, no consecutive speech, persona re-entry allowed,
no-reply weight 1.0, and random jitter 0.2.

Reject unknown or missing nested fields, out-of-range counters and durations,
non-boolean continuity flags, non-positive no-reply weights, and jitter outside
zero through one. Carry the normalized value into the complete configuration
and provide narrow projections to the existing immutable budget and responder
policy domain values.

## Consequences

Runtime assembly can derive responder policy from one validated, versioned,
environment-neutral source instead of hard-coding or accepting deployment
input. Random jitter remains normalized for the later scheduling boundary; it
does not alter selection or introduce ambient randomness in this change.
