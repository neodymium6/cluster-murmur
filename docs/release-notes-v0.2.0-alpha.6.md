# Cluster Murmur v0.2.0-alpha.6

This hotfix release restores compatibility between the fixed model-provider
request and current OpenAI Chat Completions models. It remains an alpha rather
than a production-support commitment or authorization to connect the software
to sensitive systems.

## LLM compatibility

- The bounded `max_output_tokens` configuration value is now encoded as the
  current Chat Completions `max_completion_tokens` field.
- The deprecated `max_tokens` field is no longer sent. Exact request validation
  rejects callers that try to restore it or add another provider parameter.
- The fixed `/chat/completions` endpoint, provider-neutral prompt projection,
  response decoder, retry policy, transport limits, and redaction behavior are
  unchanged.
- Unit and loopback HTTP integration tests verify both the replacement field
  and the absence of the deprecated field on the encoded wire request.

This focused change allows supported current OpenAI Chat Completions models to
use the existing provider configuration without adding a generic request
passthrough or silently changing the provider to the Responses API. Compatible
third-party endpoints must accept the current token-limit field.

## Release artifacts

The release contains one digest-addressed `linux/amd64` OCI image with at most
20 layers, an SPDX SBOM, checksums, release metadata, and signed provenance and
SBOM attestations. No mutable version or `latest` image tag is published.

A reviewed version-matching tag runs the full repository gate and creates a
draft prerelease. Publishing that reviewed draft starts a separate public
distribution smoke workflow that verifies the asset set, checksums, metadata,
image identity, and attestations.

## Deployment boundary

The repository does not contain live credentials, private endpoints, real
configuration, deployable overlays, or authorization to contact infrastructure,
a model provider, or Discord. Before any deployment, review the exact immutable
image digest, configuration, mounted secrets, network policy, storage, backup,
migration, rollback, probes, telemetry, and rollout settings in the operator's
private repository.

See the [configuration reference](configuration.md),
[deployment and artifact guide](deployment.md),
[MVP runtime contract](mvp-contract.md), and [security policy](../SECURITY.md)
before evaluating a deployment.
