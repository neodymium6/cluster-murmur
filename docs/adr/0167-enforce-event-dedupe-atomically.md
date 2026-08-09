# 0167. Enforce event deduplication with trigger starts

Date: 2026-08-09

## Status

Accepted

## Context

The pure evaluator and constrained marker table define event deduplication but
do not prevent overlapping poll and durable-dispatch paths from accepting the
same key. A separate marker transaction would leave a crash or race between
acceptance and durable trigger authorization.

## Decision

Carry the complete normalized event policy in every event-trigger execution
plan. Pass the current configuration policy explicitly from both poll and
durable event-dispatch boundaries.

Within the existing immediate trigger-execution transaction, require the exact
immutable event, reject an existing trigger/event pair, and recheck durable
cooldown before evaluating deduplication. Events without a key require no
marker. For keyed events, load and validate the exact marker and its correlated
immutable event. Atomically insert or compare-and-set the accepted marker before
inserting the started trigger execution. Any later failure rolls back both.

Treat the same event ID as an idempotent retry without extending the marker.
Return `dedupe_window` for a different event inside the active window. Do not
claim a key when cooldown prevents execution. Normalize malformed marker or
adapter failures without returning stored values.

Expose suppression reasons in poll outcomes and add only a redacted aggregate
dedupe-suppression count to durable dispatch results. Do not return marker keys,
event facts, or authorization capabilities from either cycle boundary.

## Consequences

Poll and durable dispatch now share one serialized dedupe decision and cannot
start triggers twice for different events under the same active key. Multiple
matching triggers for the accepted event remain eligible because exact-event
re-entry preserves its marker.

Retention cleanup and pruning of expired marker rows remain separate reviewed
work. The latest accepted marker can be replaced after the exact window
boundary without waiting for cleanup.
