# ADR 0037: Persist Stochastic Schedule Records First

## Status

Accepted.

## Context

The SQLite repository is supervised, and stochastic trigger sampling and
eligibility are pure. Restart-safe scheduling now needs its first durable table
without coupling scheduler execution to generic repository access.

## Decision

Add the Ecto migration path and first migration for `stochastic_schedules`.
Key each record by the complete portable trigger ID, store microsecond UTC next
and last run instants, and retain the bounded daily count and its local-date
bucket. Require the next run to be later than a present last run, bound the count
to `0..10000`, and require a date bucket for every positive count. Index the next
run for later due-schedule lookup.

Represent the row with a redacted Ecto schema and a pure changeset that mirrors
the database constraints. Do not add a generic query API, a schedule store,
automatic migration at application startup, or scheduler execution in this
change.

## Consequences

Migration commands and tests can create the first domain table, while runtime
code still cannot read or mutate it without a reviewed store boundary. A later
transactional store will define initialization, due-claim, resampling, and
daily-count update semantics.
