# 0174. Prune unreferenced event records through bounded sweeps

Date: 2026-08-09

## Status

Accepted

## Context

Expired event records can still anchor trigger executions, conversations,
dispatch handoffs, or current dedupe markers. Deleting those records would
break durable lifecycle history, while searching without a fixed scan page
could hold the SQLite writer for an uncontrolled duration. Always restarting
at the oldest referenced page would starve later unreferenced records.

## Decision

Add one narrow store operation that accepts only an exact retention plan. In a
single transaction, restore the fixed sweep cursor, load at most 100 expired
events in occurrence-time and ID order, delete only candidates with no
references in any of the four child tables, and advance the cursor past the
complete scanned page. Reset the cursor when a page contains fewer than 100
records so retained events are reconsidered on the next pass.

Return only scanned and deleted counts plus the completed-pass flag. Revalidate
loaded state and every candidate before mutation. Keep all candidate IDs and
timestamps inside the transaction and rely on foreign keys as a final guard.
Do not cascade lifecycle records or expose generic deletion or cursor access.

## Consequences

Each call performs bounded indexed work and makes progress even when its oldest
page remains referenced. Event records may outlive their configured retention
duration while referenced; later lifecycle-specific retention decisions can
make them eligible without weakening referential integrity.
