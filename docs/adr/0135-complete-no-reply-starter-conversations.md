# ADR 0135: Complete No-Reply Starter Conversations

## Context

A proven starter publication and its persona cooldown now form one exact
redacted capability. The first bounded vertical slice needs an explicit terminal
path, while reply-capable configurations must remain available to later
responder orchestration rather than being closed unconditionally.

## Decision

Revalidate the complete recorded-publication capability and resolve its exact
binding group from current configuration. Apply the existing bounded reply gate
with an injected random source. A reply outcome returns an explicit continuation
result and performs no persistence.

For an explicit no-reply outcome, pass the exact conversation advanced by the
starter append and the durable publication completion instant to an injected
narrow conversation store. Accept only the exact loaded `completed` projection
with unchanged identity, counters, and start time. Return the decision and
terminal conversation with the upstream facts in one redacted capability.

Do not select or generate a responder, publish another message, retry external
effects, alter cooldowns, or expose message and transport values.

## Consequences

The deterministic zero-probability fixture now reaches a durable bounded
terminal conversation. Configurations that permit replies receive an explicit
nonterminal result for later responder work, while no-reply paths cannot leave
the first conversation active.
