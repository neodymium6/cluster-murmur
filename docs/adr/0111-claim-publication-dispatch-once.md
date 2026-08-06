# 0111. Claim publication dispatch once

Date: 2026-08-05

## Status

Accepted

## Context

A durable `started` attempt proves intent exists before an external request,
but an idempotent start can restore that same record to more than one caller.
If each caller may invoke Discord, the application can publish the same message
more than once even without retrying after a network failure.

## Decision

Add a durable `dispatching` lifecycle state. Immediately before external
execution, compare and set one exact `started` attempt to `dispatching`. The
claim operation is deliberately not idempotent: only the caller whose update
changes one row receives the dispatch capability. A repeated or stale claim is
a conflict.

Known success may be committed only from an exact `dispatching` record. Known
failures and ambiguous interruption may close either open state. Recovery treats
an abandoned `dispatching` record like an abandoned start and never retries it.

## Consequences

At most one cooperating caller can cross the external publication boundary for
an attempt. A crash after the claim sacrifices automatic retry, including when
no request bytes were sent, in exchange for preventing duplicate Discord
messages. The next transport adapter must require a successful dispatch claim
before invoking its injected transport.
