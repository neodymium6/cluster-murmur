# ADR 0075: Validate Loaded Persona Cooldowns Centrally

## Status

Accepted.

## Context

Database constraints protect normal writes, but later persistence consumers
still need to reject forged structs, unexpected metadata, malformed decoded
values, and legacy or externally corrupted rows before making selection
decisions.

## Decision

Add one fail-closed validator for exact loaded `PersonaCooldownRecord` structs.
Require the complete schema shape, canonical loaded Ecto metadata, a bounded
portable persona ID, microsecond-precision canonical UTC instants, and a
cooldown interval from zero through the shared 365-day maximum.

Return only the stable `:invalid_persona_cooldown_record` error. Do not expose
field values, access storage, read a clock, or decide eligibility.

## Consequences

Every later cooldown restore and update path can share the same defensive
runtime boundary. Pristine constructors and forged maps cannot be mistaken for
durable capabilities.
