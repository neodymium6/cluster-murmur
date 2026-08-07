# ADR 0130: Persist Starter Messages

## Context

Starter generation now returns one validated unpublished typed message, while
the message store can atomically append a message and advance conversation
counters. Runtime flow needs a narrow boundary that connects them without
trusting forged store results or advancing counters independently.

## Decision

Revalidate the exact generated starter capability against current configuration
and supplied cooldown facts. Delegate only the original loaded conversation and
unpublished message to an injected store. Accept only an exact loaded message
record equal to the generated facts and an exact active conversation whose turn
and LLM-call counters each advanced by one while all other lifecycle facts
remain unchanged.

Return those records with the generated capability in one redacted exact value.
Preserve the store's fixed conflict and limit errors, and normalize malformed or
raised store behavior without exposing diagnostics.

Do not publish, record a persona cooldown, select a responder, or finish the
conversation.

## Consequences

Later publication planning receives durable message and conversation
capabilities that were committed together. Reusing the stale pre-append
conversation capability is rejected by the store's compare-and-set update.
