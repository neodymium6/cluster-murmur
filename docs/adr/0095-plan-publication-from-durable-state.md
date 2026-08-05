# ADR 0095: Plan Publication from Durable Message State

## Status

Accepted.

## Context

Discord publication must start from the durable message record so a restart or
repeated orchestration pass does not resend a message whose Discord ID was
already committed. The settings and payload also cross runtime boundaries and
must be revalidated before a future adapter receives them.

## Decision

Add a pure publication planner that accepts one exact loaded message record. If
the record already has a Discord message ID, return an explicit
`already_published` skip without requiring current persona or webhook settings.
For an unpublished record, revalidate the exact webhook settings, rebuild a
runtime message from the durable fields, and build the fixed Discord payload
with the exact enabled matching persona.

Return a fully redacted plan carrying the loaded record as the later
compare-and-set capability, validated settings, and fixed payload. Do not read
storage, execute Discord, retry, or record a publication here.

## Consequences

Known completed publications are idempotently skipped and malformed durable or
runtime projections fail before external work. This does not eliminate the
crash window after Discord accepts a message but before its ID is committed;
Discord webhooks provide no application idempotency key for closing that gap.
Production execution still needs an explicit recovery policy for ambiguous
outcomes and must never blindly retry them.
