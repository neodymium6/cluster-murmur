# ADR 0042: Claim Due Stochastic Schedules With Leases

## Status

Accepted.

## Context

Read-only due discovery can return the same schedule to multiple workers, and
an optimistic post-execution update does not prevent both workers from starting
the external action. The persistence boundary needs explicit, bounded execution
authority before a runtime scheduler can be added.

## Decision

Add a claim token, start instant, and expiry to each stochastic schedule. A
claim operation accepts a complete trigger ID, the expected next-run version,
and an injected UTC claim instant. In one immediate transaction, claim only that
exact version when it is due and has no live claim. Generate an opaque 256-bit
token inside application code and use a fixed 60-second lease; callers cannot
choose tokens or lease lengths.

Exclude live claims from bounded due discovery and omit claim fields from its
result projection. An expired claim becomes available at its expiry instant. A
replacement claim atomically overwrites both expired fields, so an older holder
cannot complete the new lease.

Require the opaque claim value and an independently injected UTC record instant
when recording a completed execution. Accept the update only when the persisted
trigger ID, next-run version, token, start, and expiry all match and
`claim start <= execution instant <= record instant < expiry`. Clear all claim
fields in the same transaction that advances the schedule and daily counter.
Validate the claim as a redacted capability and keep storage failures
value-free.

Do not add lease renewal, early release, action execution, clocks, randomness
for scheduling, or generic repository access. A worker must not begin work it
cannot finish inside the lease.

## Consequences

At most one live token authorizes completion for a schedule version, and stale
workers cannot overwrite a replacement claim. A lease bounds crash recovery
without adding a permanently stuck claim.

This does not make a non-transactional external action exactly once. If a
worker performs an action but cannot record completion before expiry, a later
worker may retry it. Runtime execution still needs idempotent downstream
operations or an explicit delivery policy before deployment.
