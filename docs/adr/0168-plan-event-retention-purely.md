# 0168. Plan event retention purely

Date: 2026-08-09

## Status

Accepted

## Context

The normalized event policy supplies a bounded retention duration, but storage
cleanup must not read its own clock or invent a cutoff. Passing an arbitrary
timestamp directly to deletion would also lose the correlation between the
configured duration and the operator-controlled cleanup instant.

## Decision

Add one pure retention planner that accepts the exact normalized event policy
and one injected canonical UTC instant. Subtract the retention duration in
milliseconds and return an exact plan containing the policy, planning instant,
and cutoff. Revalidate the complete plan and its arithmetic correlation before
later persistence use. Fail closed if subtraction leaves SQLite's supported
year range.

Do not query or mutate storage, read a clock, schedule cleanup, or expose a
generic deletion boundary in this change. Marker and event deletion remain
separate follow-up work.

## Consequences

Later cleanup stores can accept one bounded application-owned fact instead of
an arbitrary timestamp. Exact expiry-boundary behavior can be reviewed with
the deletion query, while this change establishes only cutoff calculation.
