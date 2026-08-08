# 0155. Run bounded stochastic cycles

Date: 2026-08-08

## Status

Accepted

## Context

Stochastic timing, durable due schedules, opaque claims, pure execution plans,
deterministic events, and atomic event/schedule commits exist independently.
Runtime assembly still needs one bounded operation that connects those fixed
boundaries without introducing external effects or generic callbacks.

## Decision

Provide one explicit stochastic cycle. Revalidate the complete configuration,
UTC instant, random source, and fixed adapters before storage access. Traverse
due schedules in cursor pages of at most 100, cap the complete cycle at the
configuration maximum of 256, require strict durable
`(next_run_at, trigger_id)` order, and correlate and evaluate the entire
collection against exact current stochastic triggers before the first claim.
Paging prevents an ineligible first page from starving eligible work behind it.

Leave inactive and daily-limit decisions unclaimed and count them as skips. For
each eligible entry in durable order, claim the exact schedule version, require
the returned lease to start at the injected instant, build one plan using
injected randomness, project its deterministic event, and commit the event with
its next schedule state atomically. Count execution only when the typed commit
result exactly correlates with that event, plan, and prior schedule. Use the
same injected UTC instant for claim, execution, and recording so every effect
remains within the fixed lease.

Treat an individual claim, planning, or commit failure as one stable aggregate
failure and continue the remaining prevalidated batch. Return counts only; do
not return schedules, events, claims, random values, or failure diagnostics.

Do not add a timer, automatically install the cycle in the application tree,
dispatch the committed event, generate text, or publish externally.

## Consequences

One call can advance a bounded deterministic due batch while stale durable
configuration fails before mutation. Ineligible work remains due and can be
re-evaluated when its active window or daily bucket changes. Temporary failures
remain protected by the opaque claim lease and are retried only after expiry.

Worker timing and dispatch of newly committed events into the existing event
trigger conversation path remain separate reviewed work.
