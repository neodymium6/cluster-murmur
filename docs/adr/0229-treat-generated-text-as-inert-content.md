# ADR 0229: Treat Generated Text as Inert Content

## Status

Accepted. Supersedes
[ADR 0228](0228-disambiguate-japanese-sentence-full-stops.md) and amends
[ADR 0066](0066-validate-runtime-messages.md),
[ADR 0067](0067-persist-message-records.md),
[ADR 0226](0226-classify-provider-output-rejections.md), and
[ADR 0227](0227-emit-redacted-generation-decisions.md).

## Context

The message validator rejected URL, domain, IP-address, and Discord
mention-looking forms. Unicode domain detection also interpreted Japanese
sentence punctuation as a possible label separator. A narrow Japanese sentence
exception still rejected ordinary colloquial output because natural language
has an open-ended set of endings and punctuation patterns.

This screening mixed two different boundaries. Generated content is displayed
text, while network access, tool use, and Discord mention expansion are external
effects. Text heuristics cannot reliably act as multilingual prose parsing or
data-loss prevention, and false rejection replaced otherwise usable provider
output with a fallback.

## Decision

Validate stored message content structurally: require nonblank valid UTF-8,
enforce the fixed byte bound, and reject forbidden control characters. Do not
classify a URL, domain name, IP address, or mention-looking form as unsafe
content. Remove the Japanese sentence and domain-detection heuristics.

Continue applying bounded mechanical whitespace normalization to provider
output before structural validation. Provider normalization can fall back for
blank output, the character limit, invalid Unicode, or an otherwise invalid
provider result. Remove the content-semantic `unsafe_content` classifier and
the now-unreachable `unsafe_output_form` fallback and telemetry class.

Keep effects controlled at their owning boundaries. Generated content grants no
HTTP, shell, SSH, database, observer, or other tool capability. Publication
always sends an empty Discord `allowed_mentions.parse` list, so message text
cannot request user, role, or broadcast mention expansion. Observation field
allowlists and generation-plan construction must keep credentials, private
endpoints, and other deployment-owned values out of prompts rather than relying
on output-text heuristics.

## Consequences

Natural Japanese and other multilingual prose no longer depends on a sentence
allowlist. Network- and mention-looking text can be stored and displayed. URLs
may be visible, clickable, or previewed by Discord, but the application does not
follow them or derive capabilities from them. Mention-like text is published
with expansion disabled.

This boundary is not a data-loss-prevention filter. A deployment that requires
stricter editorial content policy must enforce it in the facts admitted to the
generation plan or in a separate explicit presentation policy; it must not
silently broaden application capabilities or expose rejected content in logs.
