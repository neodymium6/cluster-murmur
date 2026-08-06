# ADR 0123: Poll Observer Targets Once

## Context

The read-only observer behavior, bounded target catalog, startup-owned debounce
settings, and atomic ingestion store exist independently. A runtime worker still
needs one application-owned operation that connects them without exposing
transport details or allowing one failed target to create an unbounded batch.

## Decision

Run one poll by validating state-tracking settings, listing targets exactly
once through an injected observer, normalizing the complete catalog before any
per-target call, and observing each accepted target exactly once in stable
order. Require every observation's subject to match the selected target before
passing it to the injected atomic ingestion store.

Continue through per-target observer or ingestion failures, retaining only
stable failure classes and validated committed events in one exact redacted
result. Catalog-level and startup-input failures stop before observation calls.
The operation is sequential and bounded to the catalog's 256 targets.

## Consequences

Tests can replay one complete fake-observer batch without a transport or live
infrastructure. A later supervised worker can own interval timing and call this
operation, while trigger dispatch consumes only its validated events. Poll
frequency, concurrency, retry policy, concrete MCP adaptation, and trigger
execution remain separate reviewed decisions.
