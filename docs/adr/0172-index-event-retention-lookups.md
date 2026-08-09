# 0172. Index bounded event-retention lookups

Date: 2026-08-09

## Status

Accepted

## Context

Deleting an expired event requires stable retention ordering and confirmation
that no trigger execution, conversation, dispatch, or dedupe marker still
references it. The events table is indexed only by occurrence time, while two
foreign-key child tables lack an index beginning with their event reference.
A later bounded deletion query would otherwise need a temporary tie sort or
repeated child-table scans while holding the SQLite writer.

## Decision

Replace the events occurrence-time index with a composite occurrence-time and
event-ID index. Add event-ID indexes to trigger executions and dedupe markers.
Keep the existing conversation root-event index and event-dispatch primary-key
index because both already begin with the referenced event ID.

Make the migration reversible. Do not add an event deletion API, change foreign
key actions, cascade lifecycle data, or expose any indexed value in this change.

## Consequences

A later retention store can walk expired events in deterministic index order
and check every referencing table through an event-ID lookup. This migration
does not itself delete data or change event immutability and retention policy.
