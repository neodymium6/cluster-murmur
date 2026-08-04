# ADR 0047: Persist Bounded Event Records First

## Status

Accepted.

## Context

Events now have one shared bounded validation boundary, but restart-safe event
processing has no durable representation. A future idempotent event store and
trigger-execution transaction need a constrained table without exposing the
repository or accepting a broader payload domain than matching.

## Decision

Add an `events` migration and a fully redacted Ecto record. Store complete
bounded identifiers, optional classification and dedupe values, canonical UTC
occurrence and observation instants, and an application-generated insertion
instant. Index occurrence time and the optional dedupe key.

After the shared validator accepts an event, encode previous, current, facts,
and labels as JSON text through OTP's standard JSON implementation. Preserve
JSON scalar support for previous and current while requiring facts and labels
to be objects. Bound their combined encoded representation to 512 KiB as a
defense-in-depth database limit; the tighter domain node, depth, collection,
numeric, and aggregate-text limits continue to apply before encoding.

Mirror required text, JSON shape, canonical datetime, NUL exclusion, and coarse
size constraints in SQLite. Return only redacted changesets from the record
boundary. Do not add a generic query API, event store, dedupe-window policy,
retention job, trigger bookkeeping, automatic migrations, or event execution.

## Consequences

Packaged migrations can create a constrained event table, and later stores can
use one persistence representation that already rejects malformed or unbounded
domain events. Event insertion, conflict semantics, decoded reads, dedupe
windows, and atomic trigger bookkeeping remain separate reviewed work.
