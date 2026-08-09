# 0182. Schedule recurring cycles explicitly

Date: 2026-08-09

## Status

Accepted

## Context

The bounded recurring-schedule cycle is synchronous and requires an injected
execution instant. Deployments need a repetition boundary that cannot overlap
runs or silently activate against live infrastructure.

## Decision

Add an opt-in recurring-schedule scheduler with exact validated options for the
complete configuration, cycle module, UTC clock, interval, and initial delay.
Run the cycle synchronously and create the next timer only after it returns.
Authenticate timer messages with an opaque per-run reference and ignore every
other process message.

Accept and retain only an exact bounded recurring-cycle result. Store aggregate
counts or one stable failure class in redacted status. Do not provide live
defaults and do not install the scheduler in the public application supervision
tree automatically.

## Consequences

Deployments can supervise recurring execution deliberately without overlapping
cycles. Delayed runs drift rather than accumulate concurrently, and malformed
clocks, exceptions, exits, or results become redacted failures. Runtime
composition and startup recovery gating remain separate decisions.
