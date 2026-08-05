# ADR 0071: List Bounded Conversation Message History

## Status

Accepted.

## Context

Conversation prompting and recovery need recent durable messages, but an
unbounded or ID-only query could expose unrelated content, accept stale
conversation state, or hide divergence between committed turns and messages.

## Decision

Add one read-only store operation accepting an exact loaded conversation
capability in any valid lifecycle state. In one transaction, reload every
conversation field, require the durable message count to equal the turn count
and the LLM-call count to cover it, then load at most the latest 12 messages.

Validate every returned record, conversation correlation, and nondecreasing
timeline. Terminal history may not extend past the conversation completion
instant. Return domain messages in chronological order, using the surrogate ID
as the deterministic tie-breaker. Do not expose persistence IDs, accept a bare
conversation ID, load another conversation, or assemble a prompt.

## Consequences

Current-conversation memory is bounded independently of total retained history
and fails closed on stale capabilities, counter divergence, or invalid loaded
records. Both published and unpublished generated turns remain visible to
recovery policy; later orchestration must not continue an unpublished turn as if
Discord delivery had succeeded.
