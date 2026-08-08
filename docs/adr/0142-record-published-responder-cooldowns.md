# ADR 0142: Record Published Responder Cooldowns

## Status

Accepted.

## Context

A successful responder publication now produces an exact redacted terminal
capability. Later responder selection must observe a restart-safe cooldown only
after the persona is proven to have spoken. Failed or ambiguous external
effects cannot establish that fact.

## Decision

Accept only an exact successful responder-publication capability revalidated
against current configuration, the selection-time cooldown snapshot, and
webhook settings. Treat the durable publication completion instant as
`last_spoken_at`, and derive `cooldown_until` solely from the exact current
persona's bounded `cooldown_ms` policy.

Pass only persona ID and the two derived UTC instants to the existing monotonic
cooldown store. Accept only the exact loaded record matching those facts and
return it with the publication in one redacted capability. Preserve stable
conflicts and availability errors without exposing adapter diagnostics.

Do not record cooldowns for failed or ambiguous publication, choose the next
speaker, advance or close the conversation, retry publication, or perform an
external call.

## Consequences

Responder selection can exclude a successfully published responder across
restarts. Cooldown policy remains application-owned and separate from the LLM,
publisher, transport, and conversation advancement boundaries.
