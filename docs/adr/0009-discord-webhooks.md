# ADR 0009: Use Discord Webhooks for Persona Presentation

## Status

Accepted.

## Context

The MVP needs outbound character messages with different names and avatars but
does not need inbound Gateway events.

## Decision

Publish through pre-created Discord Webhooks and override `username` and
`avatar_url` per message. Read webhook URLs from mounted secret files.

## Consequences

The MVP avoids a persistent Gateway connection and bot event scope. Mention
responses require a later consumer and cannot be inferred from webhook history.
