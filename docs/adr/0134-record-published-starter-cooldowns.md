# ADR 0134: Record Published Starter Cooldowns

## Context

A successful starter publication now produces an exact redacted terminal
capability. Persona selection must observe a restart-safe cooldown after the
persona actually speaks, but known publication failures and ambiguous external
effects must not invent a confirmed spoken fact.

## Decision

Accept only an exact successful starter-publication capability revalidated
against current configuration, the selection-time cooldown snapshot, and
webhook settings. Treat the durable publication completion instant as
`last_spoken_at`. Resolve the exact current persona and add its validated
`cooldown_ms`, defaulting an omitted optional value to zero, to derive
`cooldown_until`.

Pass only persona ID and the two derived UTC instants to an injected monotonic
cooldown store. Accept only the exact loaded record matching all three facts,
and return it with the publication in one redacted capability. Preserve stable
store conflicts and availability errors without exposing storage diagnostics.

Do not record a cooldown for failed or ambiguous publication, choose a reply,
advance or close the conversation, retry publication, or make an external call.

## Consequences

Later speaker selection can exclude a successfully published starter across
restarts. The cooldown policy remains application-owned and derived from exact
validated configuration rather than from the LLM, publisher, or transport.
