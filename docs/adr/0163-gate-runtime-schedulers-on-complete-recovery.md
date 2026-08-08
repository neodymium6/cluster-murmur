# 0163. Gate runtime schedulers on complete recovery

Date: 2026-08-08

## Status

Accepted

## Context

The poll and event-dispatch schedulers can both create or advance trigger
executions, conversations, and publication attempts. Recovery classifies all
nonterminal records globally rather than by scheduler owner. Independently
recovering one scheduler while the other remains live could therefore fail or
mark ambiguous work that is still legitimately in progress.

Expired event-dispatch leases must still wait for abandoned trigger executions
to become terminal before retry. The public application must not construct live
runtime dependencies or recovery policy automatically.

## Decision

Provide one opt-in `RecoveredRuntimeSupervisor` that validates complete poll
and event-dispatch scheduler options plus exact recovery stores before reading
time or persistence. Require both schedulers to use the same injected UTC clock.
Read that clock once and use the exact instant for the abandonment cutoff and
recovery completion time.

Start both fixed schedulers only when recovery returns no error, every bounded
mutation succeeds, and no collection fills its 100-record page. A saturated
page fails closed after processing those records; another explicit startup pass
must prove no residual page remains.

Treat both schedulers as significant temporary children in one failure domain.
Termination of either closes the shared supervisor and stops its sibling. A
parent-managed replacement must rerun the global recovery gate before starting
either scheduler again. Keep the existing poll-only recovered supervisor for a
deployment that does not run event dispatch, but require the shared supervisor
when both schedulers are enabled.

Expose a side-effect-free recovery-store validator and use it in both recovered
supervisors before clock access. Keep all boundaries outside the public
application supervision tree.

## Consequences

Global recovery cannot race live work owned by the other scheduler. Event
dispatch begins only after abandoned action lifecycles are terminal, while a
crash in either scheduler stops both before any replacement recovery pass.

Recovery remains bounded and never retries generation or publication. A single
unresolved mutation or saturated page prevents both schedulers from starting.
