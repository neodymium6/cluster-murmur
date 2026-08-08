# ADR 0151: Compose Opt-In Poll Conversations

## Status

Accepted.

## Context

The poll cycle has a safe starter-only default and a concrete consumer for
authorized bounded conversations. Its reusable context cannot contain absolute
turn timestamps because each cycle derives a fresh execution instant, and it
must not accept an unbounded scheduling callback or ambient clock.

## Decision

Add an exact relative responder schedule containing one to 256 steps. Bound
every millisecond offset, require chronological non-overlapping steps, and keep
generation and publication transports explicit and redacted. Project fresh
absolute runner turns only from the poll plan's validated execution instant.

Add an optional conversation runtime to the poll-cycle context. Preserve `nil`
as the existing starter-only behavior. When explicitly present, validate the
relative schedule, complete correlated starter/responder adapter set, and a
synthetic authorization-free coordinator input before observing any target.
After polling, project the schedule, bind each plan position to an exact
redacted event/trigger entry, and dispatch through the fixed authorized-
conversation consumer.

Do not install the scheduler in the public application tree or provide live
observer, provider, Discord, timing, secret, or routing defaults.

## Consequences

One explicitly assembled poll cycle can now progress an observed event through
starter publication and bounded responder completion without reusable
authorizations, ambient clocks, overlapping cycles, or unbounded callbacks.
Private deployment assembly remains responsible for choosing whether to enable
the runtime and for supplying reviewed transports, adapters, and relative
timing.
