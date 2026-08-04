# ADR 0011: Use Ecto with SQLite Initially

## Status

Accepted.

## Context

The single-instance MVP needs durable state transitions, event history,
cooldowns, and stochastic schedules without a separate database service.

## Decision

Use Ecto with SQLite on a Kubernetes PVC. Keep repository access behind domain
boundaries so a future persistence change does not leak into selection logic.

## Consequences

Deployment is simple and transactional. Horizontal writers are out of scope;
backup, migration, locking, corruption recovery, and PVC behavior need explicit
production procedures.
