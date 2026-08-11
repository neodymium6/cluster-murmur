# Cluster Murmur v0.2.0-alpha.3

This release supersedes the immutable `v0.2.0-alpha.2` tag. That tag passed the
complete repository validation gate and built the intended image, but its
first GHCR upload exceeded a secondary request limit before a manifest,
container package, or GitHub Release was created.

The image now contains at most 20 layers instead of inheriting the Nix builder
default of 100. Repository checks enforce the bound, and the release workflow
continues to publish only a manifest-digest alias with no mutable version or
`latest` tag.

The application behavior and standalone-alpha boundary remain the same as
`v0.2.0-alpha.2`. The release contains one digest-addressed `linux/amd64` OCI
image, an SPDX SBOM, checksums, release metadata, and signed provenance and SBOM
attestations. Artifact preparation creates a draft prerelease for human review;
publishing it starts an independent public-distribution smoke workflow.

This alpha is not a production-support commitment or authorization to connect
the software to sensitive infrastructure, a model provider, or Discord. Review
the exact immutable image, configuration, secrets, network policy, storage,
backup, migration, rollback, and rollout settings before any deployment.

See the [configuration reference](configuration.md),
[deployment and artifact guide](deployment.md),
[MVP runtime contract](mvp-contract.md), and [security policy](../SECURITY.md)
before evaluating a deployment.
