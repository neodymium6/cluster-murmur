# ADR 0090: Resolve Provider Results Purely

## Status

Accepted. Amended by [ADR 0226](0226-classify-provider-output-rejections.md)
and [ADR 0233](0233-make-generation-conversation-first.md).

## Context

A completed provider call may return accepted text, rejected text, a stable
external error, or a malformed adapter result. Later orchestration needs one
explicit decision without receiving raw provider diagnostics or combining
provider calls, fallback construction, persistence, and publication.

## Decision

Add a pure provider-result resolver. Require an exact validated persona
projection and an injected character limit between 1 and 16 KiB before
classifying the provider result.

Pass successful raw text through the provider-output normalizer. Return tagged
normalized LLM content when accepted. Return an explicit fallback decision for
rejected text, stable provider errors, and malformed provider results. Never
return or inspect provider diagnostics.

Treat invalid persona or limit inputs as orchestration errors rather than
fallback decisions. Do not call a provider, generate the fallback message,
advance conversation state, persist, or publish in this component.

## Consequences

Later orchestration receives one small deterministic decision and can build the
existing factual fallback through its separate generator. Provider diagnostics
remain behind the adapter boundary, and invalid application inputs cannot be
mistaken for external provider failure.
