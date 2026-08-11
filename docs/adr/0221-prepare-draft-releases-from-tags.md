# 0221. Prepare draft releases from reviewed tags

Date: 2026-08-11

## Status

Accepted

## Context

Artifact publication originally started from an already published GitHub
Release. That order makes the public release visible before its image, SBOM,
metadata, and attestations have passed their release-only checks. The first
GHCR publication also requires an administrator to review the newly created
private package before making it public and rerunning the workflow.

The repository needs an explicit preparation phase that can fail without
publishing incomplete release notes, while retaining the reviewed tag and the
existing digest-only registry contract.

## Decision

Start release preparation from a version-matching tag whose commit is an
ancestor of `main`. Re-run the complete repository gate, build and smoke-check
the one supported image, publish only its manifest-digest alias, require public
package visibility, generate the exact metadata, checksum, and SPDX asset set,
and attach provenance and SBOM attestations. Create a prerelease draft only
after every preparation step succeeds. Build from the validated commit rather
than the tag name and revalidate the remote tag immediately before creating the
draft. Permit a rerun to resume only an exact matching partial draft, replace
the three generated assets, and require their exact final set.

Keep publication of that draft as a separate human action. When it is
published, run an independent workflow that downloads the public assets,
requires their exact names and checksum coverage, validates metadata and SBOM
identity, anonymously inspects the digest-pinned image plus its source and
version OCI labels, and verifies both registry attestations. Resolve the
published tag once and pin every smoke checkout to that commit. Permit an
explicit published tag only for a reviewed smoke rerun.

## Consequences

A failed build, initial private-package gate, or attestation never creates a
partially populated public GitHub Release. The registry artifact can become
public before the draft is published, so tag creation remains an explicit
release-authority action and release tags must be protected against movement or
deletion. Human review of the draft controls the release announcement, while
the post-publication workflow independently checks the public consumer path.
