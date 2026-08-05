# ADR 0076: Restore and Record Persona Cooldowns

## Status

Accepted.

## Context

Selection needs optional restart-safe cooldown state, while publication or
conversation retries must not move a persona's latest spoken instant backward,
rewrite an equal instant with different policy, or trust a mutated durable row.

## Decision

Add a narrow store that fetches one bounded persona ID and returns either no
state or one centrally validated loaded record. Record explicit spoken and
deadline facts in a transaction. Insert a missing row once, accept an exact
retry idempotently, reject older or conflicting equal-time facts, and update a
newer instant through an exact all-field compare-and-set.

Reload and validate every committed candidate before returning it. A concurrent
writer that already committed the identical candidate is also an idempotent
success; every other lost compare-and-set is a stable conflict. Do not read a
clock, derive a deadline, select a persona, or update cooldown as part of
message generation or publication.

## Consequences

Persona cooldown state survives restart and advances monotonically through a
small fail-closed API. The orchestrator remains responsible for deciding the
authoritative spoken instant and calculating its deadline from validated
persona configuration.
