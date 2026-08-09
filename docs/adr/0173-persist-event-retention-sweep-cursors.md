# 0173. Persist event-retention sweep cursors

Date: 2026-08-09

## Status

Accepted

## Context

A fixed-size event-retention query must not scan past an unlimited number of
referenced events to find deletable rows. Repeatedly starting from the oldest
row would also let a full page of still-referenced events permanently starve
later unreferenced rows. An in-memory cursor would lose progress on restart.

## Decision

Add one constrained `event_retention_sweeps` table with the fixed `events`
scope. Store either no cursor or an exact occurrence-time and event-ID pair,
plus the canonical UTC instant of the latest sweep step. Permit only the one
fixed row and keep cursor fields redacted at later schema boundaries.

The table is inert in this change. Do not scan or delete events, read a clock,
add generic cursor scopes, cascade related records, or expose cursor values.

## Consequences

A later store transaction can inspect at most one indexed event page, advance
past referenced rows, and resume after restart. Completing a pass can reset the
cursor so events whose references were later removed are reconsidered.
