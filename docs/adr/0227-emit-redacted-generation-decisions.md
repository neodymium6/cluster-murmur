# ADR 0227: Emit Redacted Generation Decisions

Date: 2026-08-15

## Status

Accepted.

## Context

The model transport event can report a successful HTTP response and decoded
content even when the later provider-output boundary rejects that content and
uses the deterministic fallback. The fixed reasons introduced by
[ADR 0226](0226-classify-provider-output-rejections.md) identify this decision
without content, but operators cannot observe them after runtime resolution.

Logging a complete resolver decision would expose accepted or rejected model
output. Accepting caller-selected dimensions or diagnostics would also create
unbounded cardinality and weaken the existing operational telemetry boundary.

## Decision

Emit one fixed `[:cluster_murmur, :generation, :decision]` Telemetry event
immediately after successful provider-result resolution in both starter and
responder generation. The event contains only a count of one. Its metadata uses
the fixed `model_generation` component and either the `accepted` outcome with no
error class, or the `fallback` outcome with one allowlisted provider-failure or
output-normalization reason.

Return the resolver decision unchanged. Ignore malformed decisions and
caller-selected reasons without emitting or inspecting them. Do not attach
duration, model output, prompts, response bodies, credentials, endpoints,
domains, addresses, provider diagnostics, or caller diagnostic strings.

Emit a matching `generation decision completed` structured Logger event.
Accepted decisions use `info`; fallback decisions use `warning`. Extend the
production JSON formatter only with the new fixed message and finite metadata
values; all unlisted metadata remains discarded.

This decision amends [ADR 0217](0217-emit-bounded-operational-telemetry.md) and
[ADR 0226](0226-classify-provider-output-rejections.md).

## Consequences

Operators can distinguish provider transport or decoding failure from each
safe post-decode rejection class, including successful HTTP 200 responses that
later become fallback messages. The metric has fixed cardinality and the log
contains no generation content. Starter and responder paths add one bounded
event per successful resolution and preserve their existing returned messages.
