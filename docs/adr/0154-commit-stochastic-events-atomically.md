# 0154. Commit stochastic events atomically

Date: 2026-08-08

## Status

Accepted

## Context

A claimed stochastic plan can now project a retry-stable immutable event and
the exact next schedule state. Committing those values independently could
leave an event without advancing the claim, or advance the schedule without
the event that authorized later orchestration.

## Decision

Provide one fixed store boundary that reprojects and compares the exact event,
then inserts it and advances the claimed stochastic schedule inside one SQLite
transaction. Require the recording instant to follow execution and remain
inside the fixed claim lease.

Allow event insertion to restore an already committed identical event. This
supports the narrow recovery case where the event predates the current outer
transaction. Reject changed facts under the same scheduled event ID, invalid
claims, expired claims, and schedule compare-and-set conflicts without
advancing durable state. Roll back a newly inserted event whenever schedule
advancement fails.

Return only redacted committed records and stable error classes. Do not execute
event triggers, call a provider, publish a message, or expose generic repository
access.

## Consequences

One successful result proves that the immutable stochastic event and next-run
state committed together. Template drift fails closed without consuming the
claim, while exact precommitted events remain usable for a safe retry.

Due-schedule enumeration, claim acquisition, event-trigger dispatch, and worker
timing remain separate reviewed runtime boundaries.
