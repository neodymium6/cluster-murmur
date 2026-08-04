# ADR 0025: Validate Event Triggers as a Bounded Category

## Status

Accepted.

## Context

The configuration loader can decode trigger documents, and event matchers now
have a closed grammar, but no category boundary combines event triggers or
normalizes their actions and cooldowns. Schedule and stochastic triggers have
different timing contracts and can be added independently.

## Decision

Require each implemented trigger document to contain exactly one `triggers`
array. Accept event triggers with a portable unique ID, one bounded version 1
matcher, a `start_conversation` action referencing one portable binding ID, and
a duration cooldown. Normalize cooldowns to non-negative milliseconds and keep
binding references unresolved until complete configuration assembly.

Accept at most 256 triggers across all included files. Reject duplicate IDs,
unknown trigger and action variants, unexpected fields, malformed durations,
and invalid matchers. Normalize triggers into redacted domain values. Compile
the trigger and matcher schemas once per category parse.

Schedule and stochastic variants remain unsupported by this category parser
until their complete validation contracts are implemented.

## Consequences

Event-trigger configuration becomes bounded and deterministic without adding
runtime execution or arbitrary expressions. Include order cannot change the
normalized trigger map. Binding existence is checked later against the complete
catalog, while schedule and stochastic configuration remains startup-invalid.
