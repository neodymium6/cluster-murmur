# 0171. Schedule event-retention cycles explicitly

Date: 2026-08-09

## Status

Accepted

## Context

The bounded event-retention cycle can prune one fixed marker batch, but no
runtime worker invokes it repeatedly. A timer must not overlap cleanup cycles,
retain sensitive configuration in status, or introduce implicit deployment
defaults and live behavior into the public application.

## Decision

Provide one opt-in `EventRetentionScheduler` GenServer. Require an exact
complete configuration, narrow cycle, UTC clock, positive bounded interval,
and bounded initial delay before starting. Run each cycle synchronously and
schedule the next timer only after it returns. Bind timer messages to opaque
references so stray and stale messages cannot start cleanup.

Keep only an aggregate cycle count, one validated redacted cycle result, and
one stable error indicator in memory. Preserve the cycle's bounded storage
failure as `retention_failed`; collapse invalid clocks, malformed results,
exceptions, and exits to `invalid_cycle`. Keep later cycles eligible after
either failure.

Do not install the worker in the public application supervision tree, provide
live defaults, delete immutable event records, or add generic repository
access beyond the fixed cycle.

## Consequences

An operator can explicitly supervise non-overlapping marker cleanup. A slow
cycle delays its next run instead of accumulating concurrent work, and status
inspection cannot reveal configuration, marker keys, event facts, or storage
details. Deployment wiring and event-record retention remain separate reviewed
work.
