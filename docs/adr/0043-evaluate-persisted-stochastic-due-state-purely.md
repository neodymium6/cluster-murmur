# ADR 0043: Evaluate Persisted Stochastic Due State Purely

## Status

Accepted.

## Context

Stochastic active-hours and daily-limit policy is pure, while due discovery now
returns a bounded persistence projection. A runtime caller still needs a safe
boundary that connects those values without duplicating timezone policy or
treating an old local-date counter as current.

## Decision

Add one pure adapter that accepts a validated stochastic trigger, one redacted
unclaimed schedule projection, and a canonical injected UTC instant. Require a
matching complete trigger ID, a structurally valid schedule, and a next run at
or before the supplied instant.

Expose the eligibility policy's local bucket calculation. When a daily limit is
configured and the persisted bucket matches, pass its bounded count through.
When the persisted bucket is absent or from another local date, evaluate the
current bucket at zero. Continue to reject mismatched buckets at the lower-level
eligibility API so direct callers cannot silently relabel counts.

Return only the existing redacted eligibility decision or stable value-free
errors. Do not read storage or a clock, claim or mutate a schedule, sample a
next run, emit an event, or authorize execution.

## Consequences

Runtime orchestration can deterministically decide whether an available due
schedule is eligible before attempting its claim. Daily reset behavior remains
explicit and replayable, while storage and policy modules stay independently
testable. Claiming and subsequent action planning remain separate boundaries.
