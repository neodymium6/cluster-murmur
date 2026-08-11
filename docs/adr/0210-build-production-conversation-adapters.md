# 0210. Build production conversation adapters

Date: 2026-08-11

## Status

Accepted.

## Context

The bounded starter and responder pipelines already receive exact adapter
structs, which keeps tests and embedded uses explicit. A standalone application
entry point must not expose those structs as deployment-selected module lists.
It needs one reviewed mapping from each conversation role to the intended
production persistence, provider, publisher, and randomness implementation.

The two pipelines also require the same provider, publisher, conversation,
message, publication-attempt, and cooldown modules. That correlation was
previously checked only as part of a complete conversation input, which is too
late for effect-free worker-option assembly.

## Decision

Expose effect-free exact validators for standalone starter adapters and for the
correlated starter/responder pair. Keep the existing callback checks and require
the shared modules to be identical across both sides.

Add `ProductionConversationAdapters.build/0`. Fix every role to the
application-owned SQLite stores, `OpenAICompatibleProvider`,
`WebhookPublisher`, and the cryptographic `SystemRandom` implementation. Build
the exact existing adapter structs and pass them through the correlated
validator before returning them. Accept no caller input and keep inspection
redacted.

## Consequences

Later poll and durable-dispatch option assembly can share one validated adapter
bundle without accepting module names from configuration or environment
variables. Construction loads module contracts but does not access SQLite,
sample randomness, call a provider, publish, read a clock, or start a worker.
Embedded callers may continue to construct explicit adapters through the
existing pipeline APIs; the fixed builder defines only the standalone
production path.
