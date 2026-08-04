# ADR 0029: Select Event Triggers Deterministically

## Status

Accepted.

## Context

Individual matchers can be evaluated, but runtime policy needs a bounded,
repeatable way to identify every event trigger that matches one event. Mixing
selection with cooldown persistence or action execution would make a pure
factual decision depend on external state.

## Decision

Accept at most 256 validated event-trigger domain values, reject duplicate IDs,
and evaluate each bounded matcher in ascending trigger-ID order. Return every
matching trigger in that order. Treat invalid trigger, matcher, and event domain
values as distinct stable errors without including their contents.

Do not inspect cooldown state, choose personas, persist bookkeeping, or execute
the start-conversation action during selection. An empty trigger collection
returns an empty result without requiring an event because no factual decision
is needed.

## Consequences

Trigger candidates are deterministic and independent from include order. Later
orchestration can apply durable cooldown and dedupe policy to this bounded list
before executing any action, while matcher facts remain application-owned.
