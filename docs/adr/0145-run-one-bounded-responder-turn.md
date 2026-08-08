# ADR 0145: Run One Bounded Responder Turn

## Status

Accepted.

## Context

Responder selection, generation, publication, cooldown recording, and turn
finishing exist as separately reviewed boundaries. Runtime wiring must compose
them without adding retries, implicit recursion, ambient clocks, or partially
validated adapters.

## Decision

Add a one-turn runtime cycle with explicit timestamps, transports, settings,
and narrow adapters. Preflight every fixed contract before the continuation
planner performs its durable claim. One invocation may select at most one
responder, reserve and consume at most one LLM call, publish at most one message,
record one cooldown, and return one terminal result or exact waiting
continuation.

Propagate proven publication failure and ambiguity without retrying. Leave
multi-turn repetition and recovery to separate bounded orchestration.

## Consequences

The complete responder vertical slice can now run as one deterministic unit
while preserving durable claims and conservative external-effect semantics.
Callers cannot accidentally recurse or multiply LLM and Discord calls inside a
single cycle.
