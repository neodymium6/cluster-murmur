# ADR 0092: Load Bounded Provider Settings Without Connecting

## Status

Accepted; output-token ceiling and optional reasoning effort amended by
[ADR 0224](0224-bound-reasoning-generation-settings.md).

## Context

The generation boundary needs deployment-specific OpenAI-compatible endpoint,
model, and API-key values. Public configuration must contain only indirect
environment-variable names and numeric call limits, and constructing settings
must not itself authorize or perform a provider request.

## Decision

Load an exact normalized internal projection for the `openai_compatible`
provider. Resolve the base URL and model from named environment variables and
the API key through the bounded mounted-secret reader. Accept HTTP or HTTPS base
URLs with a host and without user information, query, or fragment. Bound the
base URL to 2,048 bytes and any explicit or default TCP port to 1 through
65,535. Bound the model to 256 bytes, timeout to 1 through 120,000 ms, and
maximum output tokens to 1 through 4,096.

Return a typed settings value whose inspection omits base URL, model, and API
key. Return stable value-free errors. Do not make an HTTP request, append a
provider-specific request path, or accept arbitrary request parameters here.
The public YAML parser will produce the normalized projection in a separate
configuration change.

## Consequences

Operator-approved private endpoints and model names may be loaded at runtime
without entering repository configuration or diagnostics. Internal plain HTTP
remains an explicit deployment choice. A later provider adapter receives fixed
settings but still needs a constrained request contract and external-error
handling.
