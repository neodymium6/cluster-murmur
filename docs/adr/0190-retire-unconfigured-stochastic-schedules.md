# 0190. Retire unconfigured stochastic schedules

Date: 2026-08-11

## Status

Accepted

## Context

Stochastic schedule state survives restart so an existing next-run version
wins over a newly sampled initial value. After configuration removes a trigger,
however, its durable state can later become due. The bounded stochastic cycle
correctly rejects that state because it cannot correlate it with the current
configuration, which would prevent the whole preflighted cycle from running.

Standalone startup needs a bounded reconciliation step before it can safely
start the stochastic scheduler. Deleting arbitrary schedule rows or exposing a
generic repository query would weaken the fixed persistence boundary.

## Decision

Extend the stochastic schedule store with one fixed retirement operation. It
accepts a validated, duplicate-free allowlist of at most 256 configured trigger
IDs, finds stale states in deterministic trigger-ID order, and deletes at most
100 in one immediate transaction. Return only an aggregate retired count and a
`saturated?` flag indicating that another startup pass is required.

Validate the bounded allowlist before repository access. Validate the selected
stale IDs again before deletion, require the deleted count to match exactly,
and normalize all persistence failures to stable value-free errors. Do not
sample initial runs, read a clock, or start a worker in this store operation.

## Consequences

A later stochastic initializer can reconcile configuration drift before live
cycles without gaining arbitrary deletion authority. More than 100 stale
schedules intentionally prevents one-pass startup completion; the operator or
parent startup loop must run another bounded pass.
