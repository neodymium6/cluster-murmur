# ADR 0045: Plan Claimed Stochastic Executions Purely

## Status

Accepted.

## Context

A due stochastic schedule can be evaluated, claimed through an opaque lease,
and advanced after successful work. Runtime orchestration still needs one safe
boundary that assembles the event template, execution timestamp, next run, and
daily bucket required by those later operations without performing the action
or mutating state.

## Decision

Build a fully redacted execution plan from one validated stochastic trigger,
the exact unclaimed due projection used to obtain a claim, its opaque 60-second
claim, a supplied canonical UTC execution instant, and an injected random
source. Re-evaluate due eligibility at the execution instant, require the claim
to match the trigger and persisted next-run version, and require execution to
occur inside its structurally valid fixed lease.

When eligible, validate the bounded emitted-event template, sample exactly one
next run from the execution instant, and return the claim, event template,
execution instant, next run, and eligibility policy's local-date bucket. When
ineligible, return the existing factual decision and do not sample randomness.
Collapse malformed inputs and adapter failures into stable value-free errors.

Do not read a clock or storage, acquire or release a claim, emit an event,
record completion, invoke an LLM, or publish externally in this pure boundary.

## Consequences

A later runner can emit only application-supplied event facts and, after
success, pass the exact planned values to the bounded completion store. Policy
changes between due discovery and execution are rechecked without consuming
randomness for skipped work. A skipped or failed plan leaves lease expiry and
retry behavior to the claim boundary; exactly-once delivery remains unresolved.
