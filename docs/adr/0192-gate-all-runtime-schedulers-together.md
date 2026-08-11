# 0192. Gate all runtime schedulers together

Date: 2026-08-11

## Status

Accepted

## Context

The shared recovered runtime already prevents poll, durable event dispatch, and
recurring execution from racing global recovery. Stochastic execution writes
events into the same dispatch path, and retention scans records referenced by
those lifecycles. Starting either worker independently could therefore overlap
a replacement recovery pass or leave a sibling live after its shared runtime
has failed.

Stochastic state also needs its own bounded reconciliation before its scheduler
can safely correlate due rows with current configuration.

## Decision

Extend `RecoveredRuntimeSupervisor` to own poll, event-dispatch, recurring,
stochastic, and event-retention schedulers as significant temporary children in
one failure domain. Validate all five exact option sets, both initializer
modules, exact recovery stores, one shared configuration, one shared UTC clock,
and the stochastic scheduler's random source before any clock or persistence
access.

Read the clock once. Complete global recovery first, recurring reconciliation
second, and stochastic reconciliation third. Pass the stochastic scheduler's
same validated random module to its initializer. Require each exact bounded
initializer result to match the corresponding configured trigger count before
starting any child.

If any worker terminates, close the shared supervisor and stop all siblings. A
parent-managed replacement must rerun every startup gate before any worker is
recreated. Keep this composition opt-in and outside the default application
tree until the separate reviewed standalone entry point supplies its complete
options.

## Consequences

No bounded scheduler remains live while a sibling replacement performs global
recovery or schedule reconciliation. Retention cannot overlap that startup
gate, and stochastic work cannot start from unreconciled durable state. One
worker failure restarts the entire five-worker group after all gates, increasing
restart scope in exchange for a single explicit consistency boundary.
