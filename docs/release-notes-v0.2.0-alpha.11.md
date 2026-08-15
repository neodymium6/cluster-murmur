# Cluster Murmur v0.2.0-alpha.11

This release improves the factual input supplied to generated conversations.
Absent optional fields are no longer presented as explicit facts, and operators
can select one validated timezone for prompt-facing timestamps without changing
canonical UTC event behavior. It remains an alpha rather than a
production-support commitment or authorization to connect the software to
sensitive systems.

## Prompt fact projection

- Optional event fields with absent values are omitted from prompt-facing fact
  maps rather than encoded as JSON `null` or synthesized values.
- Schedule and stochastic events therefore do not tell the model that their
  nonexistent previous or current states are confirmed facts.
- Observed transitions continue to include non-null previous and current
  states.
- The OpenAI-compatible request boundary accepts only the bounded allowlisted
  subset of optional fact keys, rejects unknown or explicit-null fields, and
  preserves the existing size, depth, node, and text bounds.

## Presentation timezone

- An optional top-level `presentation.timezone` setting selects the IANA
  timezone used for generated facts. Existing configurations default to
  `Etc/UTC`.
- The configured name is validated against the embedded timezone database at
  startup; prompt projection does not depend on host zoneinfo.
- Canonical event timestamps remain UTC for persistence, ordering,
  deduplication, schedule identity, and event identity. Only the prompt-facing
  representation is shifted.
- Prompts include an offset-bearing ISO 8601 `occurred_at` value and the
  corresponding IANA name in `occurred_at_timezone` for schedule, stochastic,
  and observed events.
- Provider transport reconstruction revalidates the timestamp, offset, and
  IANA zone together, including daylight-saving transitions.
- ADR 0230 records the separation between canonical and presentation time.

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
