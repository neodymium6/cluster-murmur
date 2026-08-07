# ADR 0129: Generate Starter Messages

## Context

The first-turn generation plan now contains one exact provider-neutral request,
while the provider adapter, output resolver, deterministic fallback, and typed
message boundary exist independently. Runtime orchestration needs a narrow
external-call boundary that cannot let provider failures or raw diagnostics
escape into conversation state.

## Decision

Revalidate the complete generation plan and exact provider settings. Require
the settings' provider, timeout, and output-token limit to remain identical to
the current public LLM configuration. Require an injected provider module with
the fixed generation callback, and validate one injected UTC insertion instant
against both the event and conversation start.
Call the provider exactly once through its injected transport. Resolve accepted
text through the existing normalizer with Discord's 2,000-character limit.

Build an unpublished `llm` message only from accepted text. For every provider
failure, raised diagnostic, or rejected provider output, use the existing fixed
deterministic fallback generator. Return the plan and typed message in one
redacted capability without retaining settings or transport values.

Do not retry, persist, publish, record a cooldown, or advance a conversation.

## Consequences

Later persistence receives the same validated message shape regardless of
whether content came from the provider or fallback. Provider failures become
safe conversation output rather than unbounded retry or diagnostic leakage.
