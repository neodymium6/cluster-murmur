# ADR 0069: Append Messages and Advance Conversation Counters Atomically

## Status

Accepted.

## Context

Persisting a generated message without advancing its conversation counters
would let restart recovery undercount consumed turns and LLM calls. Updating the
counters separately would expose the inverse partial state after a crash.

## Decision

Add one narrow message-store operation that accepts an exact loaded active
conversation capability and one validated unpublished message. Require matching
conversation identity, conversation-relative time, nondecreasing durable message
time, and available scalar counter capacity.

In one immediate transaction, validate the latest loaded history record,
compare-and-set the exact conversation capability, increment both the turn and
LLM-call counters, insert the message, and validate both returned records.
Fallback messages consume both counters. Return stable error classifications
without record values.

Do not select personas, enforce configured conversation budgets, invoke an LLM,
publish to Discord, accept an already published message, or update conversation
status in this operation.

## Consequences

A committed message and its durable scalar budget usage cannot diverge. Stale
conversation capabilities and out-of-order history fail closed without a
partial insert. Later orchestration must still move lifecycle status explicitly,
apply configured limits before calling this store, and record publication
identity through a separate one-way operation.
