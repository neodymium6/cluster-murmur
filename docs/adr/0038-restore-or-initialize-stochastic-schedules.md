# ADR 0038: Restore or Initialize Stochastic Schedules Transactionally

## Status

Accepted.

## Context

The constrained stochastic schedule table can retain restart-safe state, but
runtime code has no domain-specific way to use it. Startup must not overwrite a
previously committed next run or counter state with a newly sampled initial
value.

## Decision

Add a dedicated stochastic schedule store operation that accepts one validated
trigger ID and initial UTC next-run instant. In one immediate transaction,
insert the initial row on first use, ignore a primary-key conflict, and then read
the durable row. Existing state therefore wins deterministically after restart
or repeated initialization.

Validate inputs through the redacted schedule changeset before opening the
transaction. Return only the redacted record or stable `invalid_schedule` and
`storage_unavailable` classifications; do not return database exceptions,
queries, paths, or input values.

Do not expose the repository, generic queries, due-schedule listing, claiming,
resampling, counter mutation, clocks, randomness, or trigger execution through
this operation. Each later mutation receives a separate transaction contract.

## Consequences

Callers can establish one durable schedule per configured stochastic trigger
without erasing restart state. The initial next run is still calculated outside
the store, preserving clock and randomness injection. A later change must define
how due work is claimed and advanced without duplicate execution.
