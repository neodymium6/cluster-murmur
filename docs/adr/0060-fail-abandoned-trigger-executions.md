# ADR 0060: Fail Abandoned Trigger Executions

## Status

Accepted.

## Context

Pure recovery classification can identify a loaded started execution at or
before an operator-supplied cutoff. Leaving every abandoned row started forever
would prevent durable lifecycle accounting, but retrying could duplicate an
action whose external outcome is unknown.

## Decision

Add one narrow recovery store operation. Reuse the pure classifier and, only
for an abandoned exact started capability, reuse the existing compare-and-set
terminal transition to record `failed` with the stable class
`runtime.interrupted`. Return recent and terminal decisions as skips. Preserve
validation and execution conflicts from the shared boundaries.

Do not retry the action, infer whether it completed externally, change the
cooldown, read a clock, load event facts, create conversations, invoke an LLM,
or publish.

## Consequences

Recovery can durably close sufficiently old starts without risking duplicate
side effects. A concurrent normal completion or failure wins through the same
compare-and-set and recovery receives a conflict. The grace interval and cutoff
remain explicit operator or orchestration policy.
