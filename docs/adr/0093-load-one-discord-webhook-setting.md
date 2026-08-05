# ADR 0093: Load One Discord Incoming-Webhook Setting

## Status

Accepted.

## Context

The default route identifies a mounted secret containing a Discord incoming
webhook credential. The [Discord webhook resource][discord-webhooks] defines a
token-bearing URL for executing an incoming webhook and separate execution
parameters such as `wait`. Treating an arbitrary secret URL as a publication
destination would create a generic outbound HTTP capability.

[discord-webhooks]: https://docs.discord.com/developers/resources/webhook

## Decision

Load the credential only from an exact validated default-routing value through
the bounded mounted-secret reader. Accept only HTTPS on `discord.com` with the
default port and an unversioned or version 10 incoming-webhook path containing
one bounded numeric webhook ID and one bounded opaque token. Reject user
information, query, fragment, additional path segments, malformed percent
encoding, and all other destinations.

Return a typed settings value whose inspection exposes no fields. Return only
stable value-free errors. Do not execute the webhook or append query parameters
at this boundary.

## Consequences

The token-bearing URL remains outside public configuration and diagnostics,
and later publication cannot redirect this setting to a generic HTTP endpoint.
Any Discord API-version or hostname expansion requires an explicit reviewed
change. Publication confirmation, payload construction, and mention suppression
remain separate boundaries.
