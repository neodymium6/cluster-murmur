# Cluster Murmur v0.2.0-alpha.4

This release supersedes the immutable `v0.2.0-alpha.3` tag. That tag passed the
complete repository gate, published its bounded-layer image, and passed the
public-visibility check, but its content-derived upload alias collided with the
OCI Referrers Tag Schema name required for the provenance attestation index. No
GitHub Release was created.

The registry-only upload alias is now `image-sha256-<digest>`. It remains bound
to the complete manifest digest while leaving the standard
`sha256-<digest>` referrers tag available for provenance and SBOM attestations.
The digest-pinned image reference remains the only supported consumer
reference; no mutable version or `latest` tag is published.

The application behavior and standalone-alpha boundary remain the same as
`v0.2.0-alpha.3`. The release contains one digest-addressed `linux/amd64` OCI
image with at most 20 layers, an SPDX SBOM, checksums, release metadata, and
signed provenance and SBOM attestations. Artifact preparation creates a draft
prerelease for human review; publishing it starts an independent
public-distribution smoke workflow.

This alpha is not a production-support commitment or authorization to connect
the software to sensitive infrastructure, a model provider, or Discord. Review
the exact immutable image, configuration, secrets, network policy, storage,
backup, migration, rollback, and rollout settings before any deployment.

See the [configuration reference](configuration.md),
[deployment and artifact guide](deployment.md),
[MVP runtime contract](mvp-contract.md), and [security policy](../SECURITY.md)
before evaluating a deployment.
