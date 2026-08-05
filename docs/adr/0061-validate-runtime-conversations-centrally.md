# ADR 0061: Validate Runtime Conversations Centrally

## Status

Accepted.

## Context

Conversation persistence and orchestration will consume the same runtime value
across lifecycle boundaries. Repeating shape, identifier, timestamp, counter,
and participant checks in each consumer risks accepting subtly different forged
or unbounded projections.

The project does not yet define a typed message value. Accepting arbitrary terms
in the conversation message projection would bypass the required content and
response-size boundaries.

## Decision

Add one fail-closed validator for exact conversation structs. Require bounded
portable conversation and participant IDs, a bounded root event ID, a closed
status, canonical storage-safe UTC instants, ordered message activity, safe
non-negative counters, and at most 256 unique participants.

Accept only an empty message projection until a typed, separately bounded
message value exists. Return only `:invalid_conversation` and never include
supplied values in errors.

## Consequences

Later stores and lifecycle operations can share one exact runtime boundary.
Configured turn, participant, duration, and LLM-call budgets remain stricter
orchestration policy; the validator supplies hard representation limits and
does not authorize a conversation to continue. Typed message work must extend
this boundary deliberately before in-memory message projections can be used.
