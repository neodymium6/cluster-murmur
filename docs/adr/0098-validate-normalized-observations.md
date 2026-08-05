# ADR 0098: Validate normalized observations centrally

## Status

Accepted

## Context

Read-only observer adapters return normalized observations, but their behaviour
contract alone cannot guarantee that a concrete adapter supplied the exact,
bounded value expected by state tracking.

## Decision

Validate every observation at the application boundary. Require the exact
observation shape, one of the two supported health states, canonical storage
UTC time, bounded source and subject strings, and JSON-compatible fact and
label maps. Reuse the complete entity-state validation boundary by projecting
the observation as initial pending debounce progress.

Validation returns one generic error and does not log or expose supplied values.

## Consequences

State tracking can accept one stable normalized type regardless of the observer
transport. Concrete infrastructure access, debounce decisions, persistence,
and event extraction remain separate concerns.
