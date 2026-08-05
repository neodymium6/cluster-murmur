# ADR 0103: Persist publication attempt lifecycle

## Status

Accepted

## Context

Discord acceptance and recording its returned message ID cannot be one atomic
transaction. Without durable intent, a restart cannot distinguish work that was
never sent from an outcome that may already have been accepted externally.

## Decision

Persist at most one fully redacted publication attempt per message. The fixed
lifecycle distinguishes `started`, `succeeded`, classified `failed`, and
`ambiguous` interruption outcomes. Terminal records require a completion time
at or after the start; failures use only stable external error classes and an
ambiguous record uses only `interrupted`.

The message reference is a non-null foreign key with a unique index rather than
an SQLite `INTEGER PRIMARY KEY`, preventing a supplied NULL from becoming an
auto-allocated unrelated message ID.

This change defines the constrained schema and construction of a started value.
Atomic lifecycle transitions and recovery classification remain store concerns.

## Consequences

Later execution can establish durable intent before contacting Discord and can
fail closed instead of blindly retrying an unresolved start. The schema stores
no webhook URL, message content, response body, or raw diagnostic.
