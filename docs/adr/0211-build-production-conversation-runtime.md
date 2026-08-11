# 0211. Build the production conversation runtime

Date: 2026-08-11

## Status

Accepted.

## Context

Standalone startup can now construct fixed live transports, a finite responder
schedule, and correlated production conversation adapters. Poll and durable
event dispatch still require separate context structs, and assembling them in
each scheduler option boundary would duplicate sensitive closures and make it
easier for the two paths to drift.

Both cycles refresh durable persona cooldowns before observing, listing, or
claiming work. Their reusable preflight nevertheless requires a valid initial
cooldown collection, so the construction boundary needs an explicit safe
placeholder that is never treated as the current durable snapshot.

## Decision

Add `ProductionConversationRuntime.build/1`, accepting only an exact validated
`Startup.Prepared` value. Internally build the fixed live dependency and
conversation adapter bundles, derive the finite responder schedule, and create
one shared starter input with an empty initial cooldown map. Use that same input,
starter adapter set, responder schedule, and correlated conversation adapters
in both the poll and event-dispatch contexts. Fail closed unless the provider
and publisher identities in the live bundle match both sides of the
conversation adapter bundle.

Fix durable event dispatch to `EventDispatchStore`, `EventStore`, and
`EventTriggerAuthorizer`. Return those contexts together with the read-only
observer client in one inspect-redacted value. Before returning, run both
cycles' existing reusable preflight functions; those functions do not read
cooldowns or other persistence and do not execute an observation or action.

## Consequences

Later scheduler-option assembly receives one internally consistent production
conversation runtime instead of rebuilding closures or accepting adapter
selection. The empty cooldown map exists only to make construction
effect-free; every real poll and dispatch invocation replaces it with a fresh,
bounded durable snapshot before any observation or outbox access.

Construction may load module contracts and parse already prepared values, but
it does not read a clock, sample randomness, access SQLite, connect to an
external service, publish, start a worker, or begin a conversation.
