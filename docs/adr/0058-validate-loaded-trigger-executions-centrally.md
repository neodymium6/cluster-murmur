# ADR 0058: Validate Loaded Trigger Executions Centrally

## Status

Accepted.

## Context

Terminal updates and later recovery policy both consume loaded trigger-execution
records as redacted capabilities. Repeating shape, metadata, timestamp, ID, and
lifecycle checks in each consumer risks accepting subtly different forged
projections.

## Decision

Add one runtime validator for exact loaded trigger-execution records. Require
the complete schema shape and expected loaded Ecto metadata, portable trigger
and bounded event IDs, canonical UTC instants at storage precision 6, ordered
execution and cooldown times, and the closed lifecycle correlation: started or
completed without an error class, or failed with one bounded lowercase class.

Expose a stricter started-record validation for capability consumers. Return
only `:invalid_execution` without supplied values. Reuse this boundary in
terminal transitions without changing their compare-and-set behavior.

## Consequences

Recovery and lifecycle code can share one fail-closed definition of a durable
execution projection. New input plans still use their separate pre-persistence
validator because Ecto may normalize accepted UTC precision during storage.
