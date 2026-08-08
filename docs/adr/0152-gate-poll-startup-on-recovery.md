# 0152. Gate poll startup on complete recovery

Date: 2026-08-08

## Status

Accepted

## Context

The opt-in poll scheduler and bounded restart recovery already exist as
separate runtime boundaries. Deployment assembly was responsible for ordering
them, so an accidental scheduler start could admit new work before abandoned
trigger executions, conversations, and publication attempts were closed.

The public application must still avoid constructing live observers,
transports, secrets, intervals, or recovery policy automatically.

## Decision

Provide an opt-in `RecoveredPollSupervisor` that validates the complete poll
scheduler options before recovery. It reads one validated storage-UTC instant
from the scheduler's exact injected clock and uses that exact value for both
the recovery cutoff and recovery completion time.

The supervisor starts its fixed `PollScheduler` child only when recovery
returns without an error and every bounded recovery mutation succeeds. A load
error, malformed record, invalid dependency, or nonzero recovery failure count
fails startup without beginning observation. A collection that fills its
100-record recovery page also fails closed after those records are recovered;
a later explicit restart must run recovery again and prove that no residual
page remains.

Treat the scheduler as a significant temporary child. Its termination closes
the recovered supervisor instead of restarting polling directly. A parent that
supervises this boundary restarts the whole boundary, which reruns recovery
before constructing the replacement scheduler.

Keep the supervisor out of the public application supervision tree. Private
deployment assembly remains responsible for constructing its explicit options
and deciding whether to supervise it.

## Consequences

Deployments have one reviewed boundary that enforces recovery-before-polling
instead of relying on call-site convention. Scheduler failure propagates to the
boundary so a supervised replacement cannot bypass recovery.

Recovery remains bounded and never retries generation or publication. A
single unresolved recovery mutation or saturated page prevents new poll work
until an operator can inspect the durable state and restart safely.
