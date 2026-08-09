# 0169. Prune expired event dedupe markers in bounded batches

Date: 2026-08-09

## Status

Accepted

## Context

Durable deduplication retains one latest marker per key. Markers older than the
configured event retention duration no longer affect suppression because event
retention is required to be at least the dedupe window. Unbounded or arbitrary
deletion would nevertheless make cleanup a generic storage capability and
could hold the single-writer repository for an uncontrolled duration.

## Decision

Add one narrow marker store operation that accepts only an exact pure retention
plan. In one SQL statement, select markers accepted at or before the plan's
cutoff in acceptance-time and key order, and delete at most 100. Return only the
deleted count and stable value-free errors.

Replace the acceptance-time-only index with a composite acceptance-time and key
index. The composite order lets SQLite stop after the fixed candidate limit
without building an unbounded temporary sort for equal timestamps.

Treat the exact cutoff as expired. The retention policy's existing
`retention >= dedupe_window` invariant makes deletion safe at that boundary.
Keep immutable events and every execution, dispatch, conversation, and message
unchanged. Do not read a clock, schedule cleanup, accept arbitrary filters, or
return deleted marker values.

## Consequences

Callers can repeat a fixed bounded operation until it returns fewer than 100
without granting generic repository access. Event-record retention and an
opt-in cleanup runtime remain separate follow-up work.
