# ADR 0139: Plan Responder Publication

## Status

Accepted.

## Context

A responder generation claim is consumed before provider I/O and its message is
then persisted exactly once. The selection plan must not become a reusable
generation capability, but later Discord publication still needs a bounded way
to receive the exact durable output.

## Decision

Allow the synchronous responder consumer to return only a redacted delivery
containing the already-consumed plan, exact unpublished message record, and
advanced conversation record. Revalidate their complete correlation at the
dispatcher boundary; replaying the delivery cannot recreate the deleted
generation claim or call the provider again.

Build a pure responder publication planner from that delivery. Require the
exact current configuration, cooldown snapshot, selected responder, and webhook
settings, then delegate fixed payload construction to the existing publication
planner and revalidate the resulting plan independently. Do not start a durable
publication attempt, execute Discord, record cooldowns, or advance the
conversation in this decision.

## Consequences

Generation authority remains single-use while the durable message can cross a
narrow, redacted boundary into the established fixed Discord pipeline. A forged
delivery cannot publish arbitrary content because later publication persistence
still reloads and compares the authoritative message before any request.
