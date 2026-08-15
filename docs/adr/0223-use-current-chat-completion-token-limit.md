# 0223. Use the current Chat Completions token limit

Date: 2026-08-15

## Status

Accepted; budget and optional reasoning-effort configuration amended by
[ADR 0224](0224-bound-reasoning-generation-settings.md).

## Context

The fixed OpenAI-compatible request encoded the configured output bound as
`max_tokens`. OpenAI has deprecated that field in favor of
`max_completion_tokens`, and current reasoning models can reject a Chat
Completions request that still supplies the old field. This prevented a
supported model from generating text even though TLS, authentication, and the
fixed `/chat/completions` endpoint were otherwise valid.

Moving the provider to the Responses API would also require a new endpoint and
response contract. Making the token field or arbitrary request parameters
deployment-selectable would weaken the exact request boundary and allow
unreviewed provider behavior to cross from configuration into transport.

## Decision

Keep the fixed Chat Completions endpoint and response contract. Map the existing
bounded `max_output_tokens` provider setting to the current
`max_completion_tokens` request field, and never encode `max_tokens`. Continue
reconstructing the closed prompt and comparing every request field immediately
before transport, so a caller cannot restore the deprecated field or add other
provider-specific parameters.

Do not hardcode a catalog of allowed model names. Model availability belongs to
the selected deployment endpoint and changes independently of this release.
Treat a future Responses API integration as a separate reviewed provider
contract rather than silently changing the existing endpoint and decoder.

This decision amends ADR 0113's fixed request shape.

## Consequences

Current OpenAI Chat Completions models that require the replacement field can
use the existing bounded provider configuration. Compatible third-party
endpoints must accept the current Chat Completions token-limit field; endpoints
that implement only the deprecated shape are no longer compatible with this
adapter.

The public configuration remains stable, and request size, output-token,
transport, redaction, and exact-validation bounds remain unchanged. Supporting
the Responses API later will require an explicit endpoint, request, response,
and compatibility decision.
