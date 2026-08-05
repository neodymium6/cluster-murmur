# ADR 0106: Start publication attempts atomically

## Status

Accepted

## Context

Publication execution must commit durable intent before contacting Discord. A
plan may become stale between pure planning and the attempted start.

## Decision

Expose only exact message-ID reads and a narrow start operation. Revalidate the
plan against independently obtained current inputs, then open an immediate
transaction and require the freshly loaded message to remain byte-for-byte equal
and unpublished. Insert at most one started attempt. An exact retry with the same
start instant is idempotent; every different existing attempt is a conflict.

Require the injected canonical UTC start instant to be at or after message
creation. Revalidate every durable attempt before returning it.

## Consequences

An external executor can establish durable intent before the webhook call and
cannot start from a stale published message. This store performs no network call
and does not complete, fail, or recover an attempt.
