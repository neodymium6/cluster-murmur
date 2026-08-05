# ADR 0096: Persist Bounded Observation Entity-State Records

## Status

Accepted.

## Context

Observation debounce progress must survive restarts before state transitions can
produce durable factual events. The stored value includes potentially sensitive
latest facts and labels, so arbitrary maps or generic repository access are not
an acceptable persistence contract.

## Decision

Define one exact redacted entity-state value keyed by source and subject. Store
the committed state, optional different pending observation state, consecutive
count, canonical last-observed and optional last-changed instants, and bounded
JSON-compatible facts and labels. Reuse the event payload budget for recursive
runtime validation, enforce the 128 KiB boundary on the actual escaped JSON,
and encode only after the complete value is valid.

Add a fixed SQLite table with a composite source/subject primary key, enum,
debounce-progress, timestamp-order, JSON-object, and 128 KiB encoded-payload
constraints. This change adds the persistence representation only; loaded-row
validation and a narrow monotonic store API follow separately.

## Consequences

The database can represent exactly one current debounce projection per observed
entity and rejects structurally invalid direct writes. Default inspection hides
identity, times, facts, and labels. No observation is performed and no event is
classified or emitted by this record boundary.
