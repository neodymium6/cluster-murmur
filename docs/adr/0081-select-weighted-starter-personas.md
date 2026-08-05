# ADR 0081: Select Weighted Starter Personas

## Status

Accepted.

## Context

Starter candidate projection is deterministic, but choosing among multiple
positive candidates requires variability without giving a random adapter
authority over eligibility, weights, or persona data.

## Decision

Add an exact validator for redacted starter-candidate projections and a bounded
selector that accepts at most 256 unique candidates. Recalculate each component
sum and the aggregate weight within the shared finite non-negative boundary,
then normalize candidates to persona-ID order.

Return no selection for an empty or zero-total projection. Select a sole
positive candidate directly. For multiple positive candidates, pass only
`{persona_id, weight}` pairs to the injected `Random.weighted_choice/1` adapter
and require it to return an ID from the supplied set. Treat exceptions, missing
callbacks, malformed results, unexpected empty results, and unknown IDs as
stable value-free errors.

## Consequences

The random boundary performs exactly the final sample and cannot change the
application's candidate policy. Empty and deterministic decisions consume no
randomness, while weighted choices remain stable under input reordering and
replayable with a controlled adapter.
