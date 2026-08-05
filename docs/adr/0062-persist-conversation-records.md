# ADR 0062: Persist Conversation Lifecycle Records

## Status

Accepted.

## Context

Bounded conversation orchestration needs a durable lifecycle before it can
start work. Persisting arbitrary runtime projections or relying only on Ecto
changesets would leave direct database writes able to create invalid status,
counter, timestamp, and event-reference combinations.

## Decision

Add the fixed `conversations` table from the MVP contract and a redacted Ecto
record. Store a portable conversation ID, root event reference, closed status,
safe non-negative turn and LLM-call counters, canonical UTC start, and terminal
completion instant. Enforce terminal-status correlation and timestamp ordering
in database checks, with indexes for event lookup and bounded incomplete-work
scans.

Expose only a changeset for a pristine `starting` conversation with zero
counters and empty participant and message projections. Do not add generic
query or mutation access in this change.

## Consequences

The database rejects malformed lifecycle rows even outside the application
changeset. Later stores can create and transition conversation records through
narrow operations. Because SQLite does not report a stable foreign-key
constraint name, that store must translate adapter failures without exposing
details instead of relying on changeset constraint mapping. Participant
bindings and typed messages require their own explicit durable boundaries
rather than being silently discarded into this metadata table.
