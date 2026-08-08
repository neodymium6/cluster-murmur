# ADR 0140: Start Responder Publication Attempts

## Status

Accepted.

## Context

A persisted responder delivery can now be converted into a fixed Discord
publication plan. External execution must not begin until durable intent exists,
and the plan may become stale before that intent is recorded.

## Decision

Add a responder-specific start boundary that revalidates the complete fixed plan
against the exact current configuration, cooldown snapshot, persona, message,
and webhook settings. Require a canonical injected start instant at or after the
message insertion instant, then delegate to the existing narrow publication
attempt store.

Accept only an exact loaded `started` attempt correlated to the responder
message and requested instant. Return a redacted capability for later execution.
Do not contact Discord, claim dispatch, close the attempt, record a cooldown, or
advance the conversation.

## Consequences

Responder publication reaches durable intent with the same stale-message and
single-attempt protections as starter publication. Transport execution can now
consume a fully revalidated started capability without broadening HTTP access.
