# ADR 0127: Start Authorized Event Conversations

## Context

An authorized event trigger can now produce a pure pristine conversation plan,
and the conversation store can persist a pristine lifecycle independently.
Runtime action execution needs a narrow boundary between those components that
does not trust a stale or forged plan.

## Decision

Revalidate the exact conversation plan against the complete current runtime
configuration and one supplied bounded cooldown snapshot immediately before
persistence. Delegate the complete plan to an injected narrow store. In one
transaction, start the pristine conversation and compare-and-set the exact
durable trigger execution from started to completed. Rolling back either write
prevents the other from committing. This consumes each authorization at most
once, even if a caller supplies a different conversation ID on a later attempt.

Accept only exact loaded conversation and completed-execution records whose
identities, root event, counters, and instants match the plan, then return one
redacted capability containing both correlations.

Normalize malformed stores and unexpected failures to stable value-free error
classes. Preserve only the store's defined conflict, missing-event, validation,
and availability outcomes.

Do not generate content, append a message, record a persona cooldown, publish,
retry, or construct a runtime process.

## Consequences

Later generation orchestration can consume only a durable conversation start
that remains tied to the authorized event and selected configured starter. A
stale or already consumed trigger capability cannot create another
conversation. Conversation continuation and recovery remain later decisions.
