# ADR 0136: Run the Authorized Starter Pipeline

## Context

The application now has exact boundaries for authorized conversation start,
starter generation, message append, Discord publication, persona cooldown, and
explicit no-reply completion. The first vertical slice still needs one caller
that demonstrates those boundaries compose with durable SQLite state and fake
external adapters.

## Decision

Add one narrow pipeline that begins with an already durable event-trigger
authorization. Require exact redacted input and adapter structs containing all
configuration, cooldown facts, IDs, UTC instants, settings, random sources,
stores, providers, and transports. Validate the complete configuration,
authorization, correlated provider settings, webhook settings, time ordering,
transport shapes, and every fixed adapter function before the first mutation.

Compose the existing capability boundaries in order: plan and atomically start
the conversation, plan and execute fake generation, atomically append the
starter, plan and start publication, execute and atomically close the external
attempt, record the published persona cooldown, then apply reply policy. Return
the existing redacted terminal capability for no reply, an explicit published
continuation for reply, or the stable classified error, skip, failure, or
ambiguous result. Do not retry any stage.

Verify the no-reply success path with real SQLite stores and injected fake LLM
and Discord transports. Assert durable trigger consumption, one message and one
external call per adapter, published identity, succeeded attempt, cooldown, and
completed conversation. A repeated consumed capability must stop before either
external adapter.

Do not ingest observations, authorize triggers, execute a live provider or
Discord request, select or generate responders, schedule work, or implement
recovery in this pipeline.

## Consequences

The first requested fake-adapter vertical slice from event authorization
through bounded conversation completion is executable and covered by one
integration test. Remaining runtime work can build scheduling, recovery,
observation ingestion, and responder continuation around a proven narrow path
without broadening external capabilities.
