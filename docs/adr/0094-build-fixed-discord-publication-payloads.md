# ADR 0094: Build Fixed Discord Publication Payloads

## Status

Accepted.

## Context

Validated generated messages and persona identities still need a deterministic
Discord webhook body. The [Discord execute-webhook contract][discord-webhooks]
limits content to 2,000 characters, accepts username and avatar overrides, and
provides `allowed_mentions` to control mention expansion. Passing arbitrary maps
to a publisher would allow later callers to bypass those decisions.

[discord-webhooks]: https://docs.discord.com/developers/resources/webhook#execute-webhook

## Decision

Build one exact typed payload from a fully validated unpublished message and
the exact enabled persona referenced by that message. Limit content to 2,000
Unicode characters and the username override to 80 characters after applying
the existing bounded runtime validators. Preserve only the validated optional
HTTPS avatar override.

Always set `allowed_mentions` to an empty parse list. Do not accept arbitrary
embeds, components, files, polls, TTS, flags, thread routing, webhook
credentials, or execution query parameters. Redact all payload fields from
inspection and return one value-free error.

## Consequences

Discord cannot expand user, role, or broadcast mentions even if an earlier
content boundary regresses. The publisher receives one fixed body shape rather
than generic request data. Encoding, HTTP execution, confirmation behavior, and
publication persistence remain separate boundaries.
