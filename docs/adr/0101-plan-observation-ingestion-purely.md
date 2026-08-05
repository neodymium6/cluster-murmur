# ADR 0101: Plan observation ingestion purely

## Status

Accepted

## Context

Debounce evaluation and event projection are separate factual decisions, but an
ingestion caller needs one coherent result before it can coordinate durable
writes.

## Decision

Compose the pure debounce evaluator and event projector into a fully redacted
ingestion plan. Every successful plan contains the next validated entity state
and either one validated immutable event or no event. Preserve specific input
and correlation errors.

The planner does not call an observer, read or write storage, execute dedupe
policy, trigger conversations, or publish messages.

## Consequences

Later orchestration receives one deterministic unit of intended state while the
ordering and failure semantics of durable writes remain an explicit separate
decision.
