# ADR 0116: Parse LLM Startup Configuration

## Status

Accepted; output-token ceiling and optional reasoning effort amended by
[ADR 0224](0224-bound-reasoning-generation-settings.md).

## Context

The provider runtime settings boundary already resolves an endpoint, model, and
mounted API key from a normalized public projection. The version 1 manifest did
not yet parse the documented `llm` mapping, so a complete startup configuration
could not supply that projection without separately constructed values.

## Decision

Require one exact `llm` mapping in the version 1 top-level manifest. Support
only the `openai_compatible` provider and environment-variable names for the
base URL, model, and mounted API-key file path. Parse a strictly positive
timeout of at most 120 seconds and an output-token limit from 1 through 4,096.

Store the normalized redacted LLM value in both the manifest and complete
startup configuration. Allow the runtime provider-settings boundary to accept
this exact value directly, while resolving deployment values only through its
existing environment and mounted-secret readers.

## Consequences

Version 1 manifests without `llm`, with unknown LLM fields, or with direct
deployment values are invalid. Configuration loading still performs no network
call and reads no secret. Endpoint, model, and API-key values remain outside
configuration structs and their inspection output; runtime construction must
still explicitly load them before creating the provider adapter.
