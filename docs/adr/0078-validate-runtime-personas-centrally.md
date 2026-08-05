# ADR 0078: Validate Runtime Personas Centrally

## Status

Accepted.

## Context

Configuration parsing produces bounded personas, but later selection and
generation consumers may receive forged or stale in-memory structs. Repeating
partial validation would allow configuration and runtime limits to diverge.

## Decision

Add one fail-closed validator for the exact version 1 `Persona` shape. Validate
portable identity, display name, optional HTTPS avatar, bounded prompt,
enabled state, at most 256 non-negative interests, the closed normalized
behavior vocabulary, and empty reserved relationship and metadata maps.
Enforce the shared 365-day maximum on normalized cooldown milliseconds.

Run each newly parsed persona through this boundary before adding it to the
configuration catalog. Return only stable value-free errors and retain the
existing redacted inspection behavior.

## Consequences

Later speaker selection and prompt construction can revalidate complete persona
capabilities consistently. Configuration now rejects cooldown durations beyond
the runtime storage bound instead of accepting values that cannot be recorded.
