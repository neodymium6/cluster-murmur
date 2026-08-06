# ADR 0119: Commit Observation Ingestion Atomically

## Context

The entity-state store, event store, and pure ingestion planner are bounded
independently. Calling them as unrelated operations could nevertheless advance
debounce state when its projected event fails to persist, losing a factual
state transition before trigger processing can observe it.

## Decision

Add one narrow observation-ingestion store that validates a normalized
observation and debounce policy before storage access. Inside one immediate
SQLite transaction it restores the matching entity state, calculates the pure
ingestion plan, monotonically stores the next state, and idempotently stores
the optional event.

Any planning or storage failure rolls back the whole transaction and returns
only a stable error. The successful result is the redacted plan whose state and
event were committed together. This boundary does not call an observer, apply
dedupe-window suppression, execute triggers, or publish messages.

## Consequences

Later observation workers can submit normalized values through one atomic
boundary without acquiring generic repository access. Concurrent or stale
observations fail through existing monotonic state checks and may be retried by
an explicit later worker policy. Observer polling, event dedupe policy, and
trigger dispatch remain separate reviewed decisions.
