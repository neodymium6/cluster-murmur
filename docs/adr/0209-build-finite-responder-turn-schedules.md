# 0209. Build finite responder turn schedules

Date: 2026-08-11

## Status

Accepted.

## Context

Startup now captures explicit responder timing settings, while versioned
configuration owns the conversation turn and duration limits. Standalone
worker assembly needs one reusable relative schedule that combines those
bounds with the already constructed narrow generation and publication
transports. Constructing an unbounded list or inventing timing defaults in the
worker assembler would weaken the existing conversation boundary.

## Decision

Add a pure `ResponderTurnSchedule.build/4` boundary. Revalidate the exact
conversation defaults and responder schedule settings, require explicit
one-argument generation and publication transports, and build ordered relative
steps without invoking either transport.

Count the starter toward the configured conversation turn limit. Build
`max_turns - 1` responder steps, except that a one-turn conversation retains
one step so the shared conversation runtime can be validated and can
terminalize an unexpected continuation without an external effect. Reject more
than 257 total turns, because the runner accepts at most 256 responder steps.
Reject arithmetic that would exceed the shared relative-offset limit. For any
step planned before the conversation duration, also require generation and
publication start to remain strictly before that deadline, matching the runner
effect window.

## Consequences

Later production option assembly can reuse one finite, validated schedule for
poll and durable event conversations without reading a clock or introducing
hidden defaults. Oversized or internally incompatible deployment timing and
conversation combinations fail closed before worker construction. The
schedule still contains only planned timestamps and narrow transports; it does
not sleep, make network requests, access persistence, or resume conversations
after its finite bound.
