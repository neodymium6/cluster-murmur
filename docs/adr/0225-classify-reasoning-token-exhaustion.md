# 0225. Classify reasoning token exhaustion

Date: 2026-08-15

## Status

Accepted

## Context

A reasoning-capable Chat Completions model can consume its combined completion
budget with hidden reasoning before producing visible output. The provider can
return HTTP 200 with blank content and `finish_reason: "length"`, but the
response decoder previously returned the blank value as an ordinary success.
The output normalizer then selected the deterministic fallback, leaving the
external-request telemetry indistinguishable from a response whose visible
text was rejected by a later normalization rule.

The response also carries completion and reasoning token counts that are safe
to validate, but its raw body, content, and arbitrary provider metadata may
contain sensitive data. Requiring every compatible endpoint to emit all current
OpenAI metadata would unnecessarily narrow the existing integration contract.

## Decision

Within the bounded successful-response decoder, optionally accept only the
closed finish reasons `stop`, `length`, `tool_calls`, `content_filter`, and
`function_call`. When usage is present, optionally accept `completion_tokens`
and `completion_tokens_details.reasoning_tokens`; require each present value to
be a nonnegative safe integer. When both counts are present, require reasoning
tokens not to exceed the completion count. Reject malformed present metadata as
`invalid_response`.
Continue accepting responses that omit finish and usage metadata for compatible
endpoints.

Return the new stable external error `token_exhausted` when message content is
null or blank and the finish reason is `length`. Preserve nonblank partial
content for the existing output normalizer. Preserve the ordinary successful
blank result for other or omitted finish reasons, so later normalization still
owns those fallback decisions.

Classify `token_exhausted` as an error for the fixed `model_provider` external
telemetry event and allowlist only that finite error class in production JSON
logs. Validate and discard finish reasons and usage counts at the response
boundary; do not log or return them, response content, raw bodies, prompts, or
provider diagnostics.

This decision amends the response decoder in ADR 0114 and operational telemetry
in ADR 0217.

## Consequences

Operators can distinguish a reasoning-budget fallback from a normal provider
success followed by output-normalization fallback using the existing bounded
telemetry stream. Generation still uses the same deterministic fallback and
does not retry, persist provider diagnostics, or give the model factual
decision authority.

The classification depends on the provider's `length` finish reason rather than
inferring exhaustion from model names or token counts. Compatible endpoints may
omit the metadata and retain the earlier behavior, while malformed metadata
fails closed without creating new log cardinality or exposing safe-looking
fields from an otherwise sensitive response.
