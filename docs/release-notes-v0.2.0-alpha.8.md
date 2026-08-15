# Cluster Murmur v0.2.0-alpha.8

This release makes model responses that decode successfully but later use the
deterministic fallback observable through finite, privacy-safe diagnostics. It
remains an alpha rather than a production-support commitment or authorization
to connect the software to sensitive systems.

## Provider output classification

- The provider-output normalizer returns fixed classes for blank output,
  character-limit rejection, invalid Unicode, unsafe output form, and otherwise
  invalid provider output.
- The provider-result resolver distinguishes those normalization rejections
  from a provider failure without retaining response content or provider
  diagnostics.
- Message validation keeps its existing generic public error, and every
  rejection still produces the same application-owned factual fallback.
- Prompts, accepted or rejected content, raw response bodies, credentials,
  endpoints, domains, addresses, and caller diagnostic strings remain excluded
  from error values and operational reporting.

## Generation decision diagnostics

- Starter and responder generation emit one fixed
  `[:cluster_murmur, :generation, :decision]` event immediately after successful
  provider-result resolution.
- The event contains only `count: 1` and finite `component`, `outcome`, and
  `error_class` metadata. It reports accepted output or one allowlisted fallback
  reason without carrying generation content.
- The matching `generation decision completed` structured log uses the same
  dimensions, and the production JSON formatter drops every unlisted field.
- A provider transport may therefore report `outcome=ok` for an HTTP 200
  response while the separate generation event identifies a later safe
  normalization fallback.
- Regression coverage exercises HTTP 200 decode success followed by unsafe
  output rejection and verifies that only the fixed redacted reason is emitted.

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
