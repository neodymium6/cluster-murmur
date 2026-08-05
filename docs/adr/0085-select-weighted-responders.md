# ADR 0085: Select Weighted Responders

## Status

Accepted.

## Context

Responder selection must preserve both the event-group probability gate and an
independent weighted no-reply path. Allowing an injected random adapter to
invent outcomes or receive zero-probability personas would weaken convergence.

## Decision

Add an exact responder-candidate validator and a selector that first validates
the explicit reply-gate decision. Honor gate-level no reply without consuming
candidate or random capabilities. For a reply decision, accept at most 256
unique exact responder projections and one finite configured no-reply weight.
Require the no-reply weight to be strictly positive for every reply-gate
outcome. Recalculate every configured component sum and reject an
aggregate outside the shared numeric boundary.

Normalize responder outcomes by persona ID, remove zero-weight responder
outcomes, and append positive `no_reply` explicitly. Return no reply when no positive responder
exists, and select a sole positive outcome without randomness. Delegate only a
final choice among multiple positive outcomes to `Random.weighted_choice/1`,
requiring the returned outcome to belong to the supplied set.

## Consequences

Every responder decision has an explicit convergence path. Random adapters see
only bounded positive weights and cannot select an unknown or zero-weight
persona, while deterministic and gate-blocked outcomes consume no randomness.
