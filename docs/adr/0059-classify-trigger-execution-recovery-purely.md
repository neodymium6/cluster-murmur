# ADR 0059: Classify Trigger-Execution Recovery Purely

## Status

Accepted.

## Context

Bounded recovery listing exposes loaded execution state but deliberately does
not decide whether an incomplete start is old enough for recovery. Mixing that
decision with storage, clocks, or retry behavior would make it nondeterministic.

## Decision

Add a pure classifier accepting one centrally validated loaded execution and an
injected canonical UTC abandonment cutoff. A started execution at or before the
cutoff is abandoned; a later start is recent. Completed and failed executions
are terminal regardless of the cutoff.

Return only stable atoms and value-free validation errors. Do not read a clock
or repository, calculate the cutoff, change status, retry work, inspect event
facts, alter cooldowns, create conversations, invoke an LLM, or publish.

## Consequences

Operators and later orchestration can choose an explicit grace interval outside
this boundary and test exact cutoff behavior. A later store operation may use an
abandoned decision to compare-and-set the same started capability to a stable
failure without guessing whether its runtime action completed.
