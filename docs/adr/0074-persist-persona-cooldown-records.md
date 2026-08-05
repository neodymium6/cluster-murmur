# ADR 0074: Persist Persona Cooldown Records

## Status

Accepted.

## Context

Persona selection cooldowns must survive restart without retaining a complete
persona configuration or trusting unconstrained timestamps. Later selection
needs one latest spoken instant and its resulting cooldown deadline per persona.

## Decision

Add a fixed `persona_cooldowns` table keyed by a bounded portable persona ID.
Store canonical microsecond UTC `last_spoken_at` and `cooldown_until` values,
requiring the deadline to be at or after the spoken instant and no more than the
shared 365-day interval later. Mirror that shape in a redacted Ecto record
whose constructor accepts only a pristine record and the three validated facts.

Do not persist persona prompts or configuration, calculate a cooldown duration,
read a clock, select a persona, or expose generic repository access. Loaded
record validation and narrow restore/update operations follow separately.

## Consequences

The database can retain only one structurally valid cooldown projection per
persona, including a zero-duration deadline. Application code remains
responsible for deriving deadlines from validated persona policy before using a
later constrained store operation.
