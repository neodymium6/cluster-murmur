# ADR 0226: Classify Provider Output Rejections

## Status

Accepted. Amended by
[ADR 0227](0227-emit-redacted-generation-decisions.md) and
[ADR 0229](0229-treat-generated-text-as-inert-content.md).

## Context

The provider adapter already returns only decoded content or a stable external
error. The pure provider-result resolver then accepted normalized content or
selected the deterministic fallback. However, every normalization rejection
used `invalid_provider_output`, which erased whether content was blank, over the
character limit, invalid Unicode, or rejected by the safe message boundary.

Operators need a finite, privacy-safe vocabulary before later runtime telemetry
can identify the fallback stage. The classification must not expose rejected
content, prompts, raw response bodies, provider diagnostics, or caller-supplied
strings. It must also leave the user-visible deterministic fallback unchanged.

## Decision

Keep the message validator's existing generic `invalid_message` result for its
public validation boundary. Add a content classifier that returns only fixed
atoms for blank, otherwise invalid, or unsafe content.

Have the provider-output normalizer map that classifier and its own mechanical
checks to a closed set of content-free reasons: blank output, character-limit
exceeded, invalid Unicode, unsafe output form, or otherwise invalid provider
output. Continue mechanically replacing accepted control characters as defined
by [ADR 0089](0089-normalize-provider-output-safely.md).

Have the provider-result resolver return a tagged fallback with either one of
those normalization reasons or the fixed `provider_failure` reason. Discard the
reason when constructing the existing deterministic fallback message. These
pure layers neither emit logs nor retain provider content in an error value.

This decision amends [ADR 0089](0089-normalize-provider-output-safely.md) and
[ADR 0090](0090-resolve-provider-results-purely.md).

## Consequences

Runtime orchestration can count a finite decision vocabulary without inspecting
content or transport diagnostics. Tests can distinguish decode-success output
rejection from provider failure, while all rejected responses still produce the
same safe fallback message. Any later operational event must allowlist these
fixed atoms rather than accepting arbitrary diagnostic values.
