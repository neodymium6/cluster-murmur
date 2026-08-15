# ADR 0114: Decode Bounded OpenAI-Compatible Responses

## Status

Accepted; safe completion metadata and token-exhaustion classification amended
by [ADR 0225](0225-classify-reasoning-token-exhaustion.md).

## Context

The fixed provider request permits a bounded response body, but raw provider
JSON can still contain diagnostics, multiple choices, tool-call shapes, or
malformed data. Returning those values through the provider boundary would
leak details and make generation policy depend on provider-specific payloads.

## Decision

Accept only an exact response capability with a valid HTTP status and at most
64 KiB of body data. Decode successful JSON with the shared depth, node,
collection, and text budgets. Require exactly one choice containing a string
message content; ignore other bounded response metadata.

Map authentication, invalid-request, timeout, rate-limit, and server-failure
statuses to the existing stable external error classes. Never decode or return
error response diagnostics.

## Consequences

Raw bodies remain redacted from inspection and do not cross the generation
boundary. Unexpected success shapes fail closed, including multiple choices
and structured content. This decoder does not normalize generated content,
perform transport, retry, or decide whether a result should use the fallback.
