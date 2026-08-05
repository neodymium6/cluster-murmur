# ADR 0065: List Incomplete Conversations

## Status

Accepted.

## Context

Restart recovery needs to discover durable conversations that did not reach a
terminal state. An unbounded or unordered query would make recovery work depend
on database size and could return malformed loaded projections to policy code.

## Decision

Add one read-only store operation that accepts an explicit canonical UTC cutoff.
Select only `starting`, `generating`, and `waiting` records started at or before
that instant. Order by start instant and conversation ID, limit every call to
100 records, and validate every exact loaded active record before returning the
batch. Add a partial `(started_at, id)` index over the three active statuses so
SQLite can stop after the ordered limit without sorting every incomplete row.

Do not decide whether to resume, cancel, or fail a returned conversation, and do
not load events, messages, prompts, or participant data.

## Consequences

Recovery policy receives a deterministic bounded batch and remains separate
from persistence. More than 100 incomplete conversations require explicit
repeated policy, pagination, or operator handling in a later change.
