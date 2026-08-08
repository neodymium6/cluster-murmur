# ADR 0144: Continue After Published Responder Turns

## Status

Accepted.

## Context

The responder planner originally accepted only the waiting capability produced
after starter publication. A published responder turn now produces its own
waiting capability with updated runtime history and cooldown facts, but that
capability could not authorize the next bounded decision.

## Decision

Allow responder-planner input to contain either the exact initial starter
continuation or an exact responder-turn continuation. Revalidate responder
continuations against the selection-time cooldown snapshot embedded in their
publication chain, require every projected cooldown to remain present and not
be newer than the caller's validated current view, require the runtime
conversation to equal the finisher's projection, and preserve the original
starter-cooldown snapshot. This permits monotonic cooldown advances from other
conversations without selecting from stale facts; neither the recorded deadline
nor the spoken instant may regress.

Preserve the exact immutable budget, responder policy, and no-reply weight from
the previous turn, and require the next planned instant to be at or after the
publication completion that created the continuation. Resolve the root event
recursively in the responder message consumer so repeated replies retain the
same allowlisted factual source without relying on a starter-only struct path.

Resolve the configured binding from the matching continuation chain and keep
the existing synchronous preflight, random selection, durable generation claim,
explicit no-reply completion, and bounded candidate projection unchanged.

## Consequences

Each durable waiting responder turn can feed exactly one subsequent bounded
selection without reconstructing mutable history or cooldown state. Forged or
stale projections fail before consumer preflight, randomness, storage mutation,
generation, or publication.
