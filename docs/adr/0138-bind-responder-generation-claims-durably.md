# ADR 0138: Bind Responder Generation Claims Durably

## Status

Accepted.

## Context

Responder selection is sampled and cannot be reconstructed by deterministic
validation. A reusable or structurally forgeable selection could substitute a
different eligible persona, replay provider calls, or bypass LLM-call budgets.

## Decision

Atomically persist a single responder-generation claim with the sampled persona,
conversation turn, and reserved LLM-call count when moving a waiting conversation
to generating. The synchronous responder consumer must delete that exact claim
before provider I/O. Append the resulting message through a reserved path that
advances the turn without counting the already reserved LLM call again.
Returning from generating to waiting requires both consumption of the claim and
a complete, validated reserved turn. Terminal recovery instead deletes any
outstanding claim atomically with the terminal transition.

Explicit no-reply selections complete the exact waiting conversation instead of
creating a generation claim. Conversation history remains quoted context and may
not introduce facts or instructions.

## Consequences

Forged persona substitutions, direct callback calls without a durable claim, and
replays fail before provider I/O. Provider failures still consume the reserved LLM
budget, favoring bounded at-most-once generation over unbounded retries. Recovery
may terminally close generating conversations whether the claim is still
outstanding or its provider attempt did not reach message persistence, without
leaving a claim that blocks later work.
