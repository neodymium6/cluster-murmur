# ADR 0150: Consume Authorized Conversations

## Status

Accepted.

## Context

The authorized-conversation coordinator can run one exact starter and finite
responder schedule, while poll dispatch authorizes a bounded batch only after
its concrete consumer preflights every match. The existing starter-only
consumer must remain available, and responder inputs must not receive reusable
authorizations or bypass batch validation.

## Decision

Add a separate opt-in poll consumer for authorized conversations. Its redacted
context contains one authorization-free coordinator input plus the exact
expected event, trigger, and execution instant for every planned position, and
one fixed correlated adapter set. Validate the complete batch, stable input
positions, unique conversation IDs, event timing, schedules, and adapters
before the dispatcher authorizes its first action.

At consumption, revalidate the durable authorization, correlate its event,
trigger, and execution instant with the indexed expected match, revalidate that
entry's shared runtime, insert the authorization into only the corresponding
starter input, and immediately invoke the fixed authorized-conversation
coordinator. Collapse all non-successful outcomes to stable consumer errors and
never return a reusable authorization.

## Consequences

Poll dispatch can opt into bounded responder execution through a concrete
consumer without altering the existing starter-only path. Relative schedule
construction and reusable poll-cycle selection remain separate runtime
assembly work.
