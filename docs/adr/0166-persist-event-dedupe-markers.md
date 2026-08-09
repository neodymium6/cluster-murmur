# 0166. Persist exact event dedupe markers

Date: 2026-08-09

## Status

Accepted

## Context

The pure event dedupe evaluator produces a redacted marker for the last event
accepted under each dedupe key. Enforcing that decision across concurrent poll
and durable-dispatch paths requires one database-owned compare-and-set target,
but its schema and loaded-value validation should be reviewed before mutation
semantics are added.

## Decision

Add an `event_dedupe_markers` table keyed by the bounded dedupe key. Store the
correlated immutable event ID and canonical UTC acceptance instant. Require the
event through a foreign key, constrain all text and datetime values at the
database boundary, and index acceptance time for later bounded retention.

Provide a redacted Ecto record that accepts only a pristine record and one exact
pure marker. Provide a separate validator that accepts only exact loaded records
with microsecond precision. Do not expose reads, writes, replacement policy,
trigger execution, or cleanup in this change.

SQLite does not report a stable foreign-key constraint name through the adapter,
so the changeset does not claim to translate orphan insertion failures. Direct
repository insertion is not a public boundary. The follow-up store must catch
and normalize every adapter failure while the database foreign key remains the
authoritative integrity constraint.

## Consequences

The next transaction can lock one stable key, evaluate the current marker, and
commit its replacement with a trigger start without adding a generic query API.
Malformed or orphaned marker rows fail at schema or loaded-value boundaries.

The table remains inert until the follow-up narrow store installs atomic
mutation semantics. The acceptance-time index does not itself delete data.
