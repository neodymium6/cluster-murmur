# 0181. Run bounded recurring schedule cycles

Date: 2026-08-09

## Status

Accepted

## Context

Recurring schedule state, pure planning, deterministic event projection, and
atomic persistence are available as separate boundaries. A runtime composition
must prevent stale configuration or malformed storage pages from causing a
partial batch of claims.

## Decision

Add one synchronous recurring-schedule cycle. Validate its exact configuration,
UTC execution instant, and fixed adapters before storage access. Load and
correlate every due state with an exact current recurring trigger before the
first claim, preserving durable cursor order and accepting at most 256 states
across pages of at most 100.

For each validated state, claim its exact due version, build the pure execution
plan, deterministically project the event, and use the atomic recurring commit
boundary. Validate returned claims and commit results against the call before
counting an execution. Continue the prevalidated batch after an individual
claim or commit conflict.

Expose only bounded aggregate counts. Do not read a clock, calculate timers,
dispatch events, invoke providers, or install the cycle in the public
application supervision tree.

## Consequences

One call performs a bounded, deterministic batch without allowing configuration
drift discovered during loading to leave earlier schedules claimed. A separate
opt-in scheduler must inject execution instants and invoke this cycle without
overlap.
