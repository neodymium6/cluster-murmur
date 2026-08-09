# 0184. Gate recurring runtime startup

Date: 2026-08-09

## Status

Accepted

## Context

The shared recovered runtime starts poll and event-dispatch schedulers only
after globally abandoned action work is closed. Recurring execution creates
events for that same dispatch path and also requires state reconciliation before
its first cycle. Starting it independently could race global recovery or leave
one scheduler alive while another replacement reruns startup mutations.

## Decision

Extend the opt-in recovered runtime supervisor to own the poll, event-dispatch,
and recurring-schedule schedulers in one failure domain. Validate all three
exact scheduler option sets, one recurring initializer module, exact recovery
stores, a shared configuration, and a shared UTC clock before reading time or
persistence.

Read the clock once. Complete global recovery first, then run recurring state
initialization with the same instant and accept only its exact bounded aggregate
result when its count equals the configured recurring-trigger count. Start all
three significant temporary workers only after both gates succeed. Termination
of any worker closes the supervisor so a parent-managed replacement must rerun
recovery and initialization before replacing the group.

Keep this composition outside the public application supervision tree and
provide no live dependencies or defaults.

## Consequences

Recurring event creation cannot begin during abandoned action recovery, and
removed schedule state is reconciled before any scheduler can read it. An
incomplete recovery, saturated retirement page, malformed initialization, or
worker crash fails the complete group closed. Deployments that opt into the
three runtimes must construct one coherent shared configuration and clock.
