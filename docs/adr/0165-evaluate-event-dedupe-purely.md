# 0165. Evaluate event deduplication purely

Date: 2026-08-09

## Status

Accepted

## Context

The version 1 configuration now supplies a bounded event dedupe window. Poll
and durable event-dispatch paths can overlap, so a read-only lookup followed by
an unrelated trigger start would leave a race where both accept the same key.
The factual policy still needs a pure representation before persistence can
apply it atomically.

## Decision

Add a pure `DedupeEvaluator` that accepts one validated event, the last durable
marker for its dedupe key, the normalized event policy, and an injected UTC
instant. An event without a dedupe key is accepted without a marker. The first
keyed event creates a marker. A different event with the same key is suppressed
while the configured window is active and accepted exactly at the boundary.

Treat the same event ID as an idempotent retry: accept it with the unchanged
marker so retries cannot extend the window. Require a supplied marker to match
the event's key and reject future or forged markers. Keep every marker value
out of inspection.

Do not read or write storage, execute a trigger, or select a runtime path in
this change. A later transaction must persist the marker and trigger start
atomically before either poll or durable dispatch uses the decision.

## Consequences

Both runtime paths can share one deterministic boundary and stable
`dedupe_window` suppression reason. Exact event retries remain eligible for
downstream idempotency checks without moving the suppression deadline.

The evaluator alone does not enforce deduplication. Until the follow-up store
transaction is installed, configured windows remain non-operative.
