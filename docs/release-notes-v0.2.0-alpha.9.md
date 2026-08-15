# Cluster Murmur v0.2.0-alpha.9

This release admits narrowly bounded Japanese multi-sentence model output that
uses ideographic full stops while preserving fail-closed Unicode-dot network
reference validation. It remains an alpha rather than a production-support
commitment or authorization to connect the software to sensitive systems.

## Japanese output validation

- A complete line containing two or more closed Japanese sentences can use
  ideographic full stops as sentence boundaries without being misclassified as
  a domain-like form.
- The exception uses a fixed character allowlist of Japanese scripts, numbers,
  combining marks, and bounded Japanese punctuation with a fixed set of
  sentence endings. Latin characters, inter-sentence whitespace, path
  punctuation, and fixed Japanese network-reference cues keep the line under
  domain detection.
- URL, network-path, and IP-address checks continue to treat ideographic,
  fullwidth, and halfwidth dots as ASCII dots.
- A bare Japanese sentence chain and a syntactically identical IDNA label chain
  cannot be distinguished from raw text alone. ADR 0228 records the narrow
  deterministic interpretation and its fail-closed limits.
- Clause splitting and validation use bounded linear scans, with regression
  coverage for a maximum-size Japanese near match.

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
