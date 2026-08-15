# Cluster Murmur v0.2.0-alpha.10

This release treats bounded network- and mention-looking model output as inert
display text, removing multilingual content heuristics while retaining strict
capability and publication boundaries. It remains an alpha rather than a
production-support commitment or authorization to connect the software to
sensitive systems.

## Generated content policy

- Stored messages require nonblank valid UTF-8, remain under the fixed byte
  limit, and reject forbidden control characters. Provider output remains under
  the configured publication character limit.
- URLs, domain names, IP addresses, Discord mention-looking forms, and natural
  multilingual punctuation are no longer classified as unsafe content.
- Provider normalization falls back only for blank output, the character limit,
  invalid Unicode, or an otherwise invalid provider result. The obsolete
  `unsafe_content` and `unsafe_output_form` classes were removed.
- Generated text grants no network, tool, observer, shell, database, or other
  application capability. Observation allowlists and generation-plan
  construction remain responsible for excluding deployment-owned sensitive
  values from model context.
- Discord publication continues to send an exact empty `allowed_mentions.parse`
  list, so user, role, and broadcast mention expansion remains disabled even
  when the displayed text resembles a mention.
- ADR 0229 records the content-versus-capability boundary and supersedes the
  Japanese sentence-ending heuristic from ADR 0228.

URLs may be visible, clickable, or previewed by Discord. The application does
not follow them or derive capabilities from their text.

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
