# ADR 0122: Bound Observer Target Catalogs

## Context

The read-only observer behavior can list target identities, but orchestration
must not trust an external response's size, shape, uniqueness, or ordering.
Iterating an unbounded or duplicate list could multiply observer calls and make
otherwise deterministic polling depend on transport response order.

## Decision

Normalize only exact atom-keyed target maps containing one bounded portable ID.
Accept at most 256 unique targets and at most 64 KiB of target-ID text in one
catalog, then sort normalized redacted target values by ID. Revalidate the
exact catalog and every target before later polling.

The catalog boundary performs no observer or infrastructure call and carries
no endpoints, credentials, tool names, or arbitrary transport arguments.

## Consequences

A later poll runner can make a bounded deterministic sequence of named
`observe_target/1` calls. Concrete adapters remain responsible for normalizing
raw transport responses into the behavior's narrow atom-keyed maps. Poll
frequency, concurrency, partial-failure policy, and observation ingestion stay
separate reviewed decisions.
