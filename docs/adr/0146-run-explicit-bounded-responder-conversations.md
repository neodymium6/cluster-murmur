# ADR 0146: Run Explicit Bounded Responder Conversations

## Status

Accepted.

## Context

One responder turn can now cross selection, generation, publication, cooldown,
and durable finishing as a bounded unit. A conversation still needs to consume
exact continuations until application-owned policy terminates it, without
introducing ambient clocks, retries, or open-ended recursion.

## Decision

Add a responder conversation runner that accepts a non-empty schedule of at
most 256 exact turn specifications. Validate the complete schedule, shared
settings, adapters, and first continuation before the first durable selection.
Every specification supplies its planning, generation, publication-start, and
publication-completion instants plus both external transports.
For any turn planned while the immutable duration budget is still open,
generation and publication dispatch must both begin before its absolute
deadline. A turn planned at or after that deadline can only take the
deterministic no-reply path and therefore performs neither effect.

Delegate each turn to the one-turn runtime boundary. Only its exact waiting
continuation may seed the next planner input, while configuration, budget,
policy, starter cooldown snapshot, webhook settings, provider settings, and
no-reply weight remain fixed. Stop immediately on completion, no reply, known
publication failure, ambiguous publication effect, or any error. If the finite
schedule ends while the immutable budget remains open, return the waiting
continuation without manufacturing another turn.

## Consequences

Responder conversations can progress deterministically through multiple turns
while each invocation remains finite and every external effect remains
single-attempt. A caller may provide another bounded schedule for a returned
continuation, but immutable durable budgets still prevent that from extending
the conversation indefinitely. Recovery and deployment-specific scheduling
remain separate concerns.
