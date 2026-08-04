# ADR 0023: Validate One Indirect Default Route

## Status

Accepted.

## Context

The MVP publishes through one pre-created Discord webhook. Accepting webhook
URLs directly in YAML would mix public configuration with credentials, while
generic or group-specific routing would expand the outbound capability before
its policy is defined.

## Decision

Require exactly one version 1 routing document with exactly one `default`
route. The route contains only `webhook_secret_file_env`, the name of an
environment variable whose value is a mounted secret-file path. Environment
variable names use the portable ASCII grammar `[A-Za-z_][A-Za-z0-9_]*` and are
limited to 128 bytes.

Reject empty routing categories, multiple default documents, direct URLs,
unknown fields, and the reserved `routing.groups` shape. Return a redacted
routing value and stable errors. Reading the named environment variable,
opening the secret file, and validating the webhook URL remain a later bounded
startup stage.

## Consequences

Public YAML cannot contain a webhook credential or choose an arbitrary outbound
destination. Version 1 requires one default route even when other categories
are empty. Multi-channel or group-specific routing requires a future contract
and security review.
