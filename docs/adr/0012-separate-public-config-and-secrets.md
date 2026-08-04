# ADR 0012: Separate Public Configuration from Private Deployment Secrets

## Status

Accepted.

## Context

Schemas and reusable examples belong in a public repository, while webhook
URLs, API keys, endpoints, identities, and deployment routing are sensitive.

## Decision

Keep secret values out of YAML. Public configuration stores environment-variable
names that point to mounted secret files. Keep concrete private overlays in a
separate infrastructure repository.

## Consequences

Public examples remain safe and reusable. Runtime startup must validate secret
references, file permissions, size limits, and fail-closed error handling.
