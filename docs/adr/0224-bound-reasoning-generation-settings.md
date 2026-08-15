# 0224. Bound reasoning generation settings

Date: 2026-08-15

## Status

Accepted

## Context

The public LLM configuration limited `max_output_tokens` to 4,096. The current
Chat Completions `max_completion_tokens` field bounds visible output and hidden
reasoning tokens together, so a reasoning model can consume that complete
allowance before producing visible text. Current OpenAI guidance recommends
initially reserving at least 25,000 tokens for reasoning and output while an
operator evaluates a model's requirements.

Reasoning models also expose an effort control, but accepted values and defaults
vary by model. Always sending one application-selected default would change
existing provider behavior and could make non-reasoning or third-party endpoints
reject an otherwise compatible request. Allowing an arbitrary request map would
weaken the fixed provider boundary.

## Decision

Raise the finite `max_output_tokens` validation ceiling to 32,768 across public
configuration and loaded provider settings. Keep the field required and retain
its existing lower bound, exact propagation, and correlation checks.

Add one optional public `reasoning_effort` field with the closed values `none`,
`minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Normalize a configured
value to an atom, propagate it through the exact redacted LLM and provider
settings projections, correlate it wherever generation settings are
revalidated, and encode it as the Chat Completions `reasoning_effort` string.
When the field is omitted, retain `nil` internally and omit it from the wire
request so existing endpoint defaults and compatible providers remain
unchanged.

Do not infer support from the model name or maintain an application-owned model
catalog. Operators must choose an effort supported by the configured endpoint;
a provider rejection remains a stable `invalid_request` outcome. Do not expose
any other provider parameter through configuration.

This decision amends the provider settings boundary in ADR 0092, the fixed
request decisions in ADRs 0113 and 0223, and the public manifest decision in
ADR 0116.

## Consequences

Operators can reserve enough bounded completion space for initial reasoning
model evaluation or explicitly reduce reasoning effort. The default public
example now demonstrates a 32,768-token allowance and low effort, while an
existing configuration that omits effort continues to encode the same request
shape as before this decision.

The higher ceiling permits greater per-call cost and latency, but remains
finite and deployment-selected; conversation duration, LLM-call counts,
timeouts, response bytes, and publication bounds are unchanged. A model may
still need a different budget or reject an unsupported effort, and the
application does not hide those provider-owned constraints.
