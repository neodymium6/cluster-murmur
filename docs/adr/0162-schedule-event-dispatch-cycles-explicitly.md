# 0162. Schedule event-dispatch cycles explicitly

Date: 2026-08-08

## Status

Accepted

## Context

The bounded event-dispatch cycle can consume durable outbox handoffs, but no
runtime worker invokes it repeatedly. A timer must not overlap cycles, retain
sensitive runtime configuration in status, or introduce implicit deployment
defaults and live behavior into the public application.

## Decision

Provide one opt-in `EventDispatchScheduler` GenServer. Require an exact complete
configuration, dispatch context, fixed persistence and authorizer adapters,
narrow cycle, UTC clock, positive interval, and bounded initial delay before
starting. Reuse the cycle's public runtime validation without reading the
outbox. Run each cycle synchronously and schedule the next timer only after it
returns. Bind timer messages to opaque references so stray and stale messages
cannot start work.

Keep only an aggregate cycle count, one validated redacted cycle result, and one
stable error class in memory. Preserve the cycle's bounded storage-read failure
as `dispatch_failed`; collapse invalid clocks, malformed results, exceptions,
and exits to `invalid_cycle`. Keep later cycles eligible after either failure.

Do not install the worker in the public application supervision tree, provide
live defaults, perform recovery, or add any action callback or external access
beyond the fixed cycle dependencies.

## Consequences

An operator can explicitly supervise non-overlapping durable event dispatch.
A slow cycle delays its next run instead of accumulating concurrent work, and
status inspection cannot reveal configuration, credentials, event facts, or
authorization capabilities.

Startup recovery ordering and operational event retention remain separate
reviewed work.
