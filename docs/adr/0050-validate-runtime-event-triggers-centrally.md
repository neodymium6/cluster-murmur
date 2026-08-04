# ADR 0050: Validate Runtime Event Triggers Centrally

## Status

Accepted.

## Context

Event-trigger selection performs local outer-shape checks while matcher
evaluation separately validates nested predicates. Later cooldown and durable
execution planning need the same runtime trigger boundary, and forged structs
with extra fields must not bypass the closed configuration shape.

## Decision

Add one event-trigger validator for the exact runtime struct, portable trigger
and binding IDs, fixed action, non-negative cooldown, and complete bounded
matcher. Expose matcher-only validation from the deterministic matcher module so
all runtime consumers share its operator, field, scalar, collection, duplicate,
and exact struct-shape checks.

Make event selection call the shared trigger validator before sorting,
deduplicating, or evaluating matchers. Preserve stable `invalid_trigger` and
`invalid_trigger_matcher` classifications without returning rejected values.

Do not apply cooldowns, access persistence, execute actions, select personas,
or alter configuration parsing in this change.

## Consequences

Future pure cooldown planning and persistence boundaries can reject forged
triggers identically to selection. Runtime matcher evaluation still revalidates
the matcher as defense in depth before reading event fields.
