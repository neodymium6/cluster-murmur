# 0219. Publish attested release images

Date: 2026-08-11

## Status

Accepted

## Context

The repository builds and smoke-checks a hardened OCI-compatible archive, but
operators cannot consume a repository-published immutable image or verify its
source revision and contents. Publishing ad hoc local builds would omit a
stable digest, supported-platform declaration, SBOM, and trusted provenance.

## Decision

Publish artifacts only from a GitHub `release` event, and target a dedicated
`release` environment that repository administrators must protect with required
reviewers. Require the tag to equal `v` plus the repository `VERSION`, and
require the tag revision to equal the release event revision. Rebuild and run
the existing container-level smoke check from that tag before any registry
mutation.

Convert the deterministic Nix archive to an OCI layout, calculate its manifest
digest locally, and use an upload alias derived from the complete digest. Do not
publish a version tag, `latest`, or another channel alias. Verify the registry
digest again after publication and make the digest-pinned reference
authoritative. Because the upload alias names its intended content rather than
a release channel, retrying cannot silently replace a version binding.
The Nix Skopeo invocation disables only its absent local signature-policy file
for these two copies; registry TLS verification and every digest comparison
remain enabled, and the following steps generate the release signatures.

Initially support and declare only `linux/amd64`. Adding an architecture
requires a native reviewed build and smoke path plus a multi-platform index; do
not claim an architecture based only on evaluation or emulation.

Generate an SPDX 2.3 SBOM from the exact OCI layout. Attach the SBOM, bounded
release metadata, and checksums to the GitHub Release. Use GitHub's short-lived
workflow identity to generate build-provenance and SBOM attestations for the
published image digest and attach them in GHCR. Grant only contents, packages,
identity-token, and attestation permissions; store no registry credential.
Reject an empty inventory or one that omits the exact Cluster Murmur version.

## Consequences

Operators have one digest-pinned image reference, an explicit platform list,
downloadable inventory, and independently verifiable source provenance. A
release publication performs the heavy container smoke check once, outside
ordinary pull-request work.

The first publication still requires repository administration to protect the
`release` environment and release tags. GHCR initially creates a private
package, so the workflow stops after the first digest upload until an
administrator reviews it, irreversibly makes it public, confirms anonymous
digest access, and reruns the workflow. Multi-platform publication remains
explicit future work.
