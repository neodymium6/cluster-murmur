# Cluster Murmur v0.2.0-alpha.5

This release strengthens the standalone alpha's TLS startup boundary and makes
the project easier to understand and maintain. It remains an alpha rather than
a production-support commitment or authorization to connect the software to
sensitive systems.

## Runtime TLS trust

- The standalone OTP application now initializes its certificate store before
  constructing production children. When `SSL_CERT_FILE` is configured, the
  path and bundle are bounded and validated before OTP loads them.
- Startup fails closed with a stable redacted error when the configured bundle
  cannot be read, contains no usable certificates, or produces an empty trust
  store. Paths, certificate contents, and loader details are not logged.
- If `SSL_CERT_FILE` is absent, OTP may use its platform discovery, but startup
  still requires a non-empty certificate store.
- Release and extracted-container checks exercise a deliberately isolated CA
  bundle and verify its exact certificate DER is present. This prevents a host
  certificate store from making the packaged-runtime check pass accidentally.

These changes make the fixed HTTPS observer, model-provider, and Discord
transports usable in the minimal OCI image without expanding their request
surface, redirect policy, retry behavior, or response bounds.

## Runtime maintenance

The event-dispatch cycle has been decomposed into focused batch-loading,
consumer-preparation, and claimed-execution modules. The refactor preserves the
durable consumer preflight before dispatch and keeps the existing bounded batch,
lease, failure-classification, and recovery behavior.

## Product and documentation

- The README now introduces Cluster Murmur through its product experience: a
  read-only observation becomes an application-selected event and then a short,
  bounded character conversation.
- Configuration, runtime contracts, design rationale, operations, and
  historical evidence are split into audience-focused pages reachable from a
  task-oriented documentation index.
- The product boundary remains explicit: Cluster Murmur is not monitoring,
  incident response, remediation, or a generic infrastructure agent.

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
