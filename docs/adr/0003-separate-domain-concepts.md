# ADR 0003: Separate Observation, Event, Persona, and Binding

## Status

Accepted.

## Context

Mixing source snapshots, meaningful changes, character identity, and
cluster-specific affinity would make personas hard to reuse and decisions hard
to test.

## Decision

Model observations, events, personas, and bindings independently. Bindings map
event characteristics to weighted persona candidates.

## Consequences

Configuration is more verbose but domain decisions remain composable,
testable, and portable between clusters.
