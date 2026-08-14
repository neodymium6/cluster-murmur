# Build and release artifacts

This page defines supported build outputs and the tagged release procedure. It
is part of the [deployment and operations guide](../deployment.md).

## Build the OTP release

Build the immutable, nondistributed release from the pinned Nix inputs:

```bash
nix build .#cluster-murmur
```

The release contains no generated Erlang cookie, runtime configuration, or
credentials. Its production entry point owns the fixed transport and worker
assembly.

## Prepare SQLite

Set `CLUSTER_MURMUR_DATABASE_PATH` to an approved absolute path. Its existing
parent directory must be private and controlled by the runtime identity. Stop
every application instance that uses the database before running migrations.

For local artifact evaluation, create a private ignored directory and apply the
packaged migrations explicitly:

```bash
mkdir -p .local
chmod 0700 .local
CLUSTER_MURMUR_DATABASE_PATH="$PWD/.local/cluster-murmur.sqlite3" \
  ./result/bin/cluster_murmur eval \
  'ClusterMurmur.Release.migrate!()'
```

Application startup never runs migrations automatically. Migration failures use
a stable redacted error and must be resolved before starting runtime work. The
[configuration reference](../configuration.md) defines the complete database-path
validation and migration contract. A deployment operator must separately
provision its persistent parent directory with mode `0700` and ownership for the
runtime identity.

## Build the container archive

The container artifact is available on Linux:

```bash
nix build .#container-image
docker image load -i result
```

The scratch-based image:

- runs as numeric user and group `65532:65532`;
- starts the nondistributed release through Tini;
- includes a CA bundle and points `SSL_CERT_FILE` at its immutable Nix store
  path;
- declares no ports, volumes, health check, credentials, or deployment
  configuration; and
- includes standard OCI labels and the complete runtime closure.

Repository checks validate the archive metadata and closure, remove write
permission except from the intended temporary and data paths, migrate an
isolated database, and smoke-run the extracted entrypoint. The startup smoke
also requires OTP to expose a non-empty CA certificate store after loading the
configured bundle. These archive-level checks do not apply container-runtime
mount, identity, or privilege controls.

## Published release artifacts

Push one reviewed tag whose name is exactly `v` plus `VERSION` and whose commit
is on `main`. The tag workflow validates that identity and ancestry, requires
the matching release-notes file, and reruns the complete repository gate. It
then rebuilds and container-smoke-checks the tagged source and publishes exactly
one supported platform, `linux/amd64`, to
`ghcr.io/neodymium6/cluster-murmur`.

The workflow does not publish a version tag, `latest`, or another channel
alias. Its registry-only `image-sha256-<digest>` upload alias contains the
complete manifest digest without colliding with the OCI referrers tag used for
attestations. The digest-pinned reference in release metadata is the only
supported reference. Publication reads the manifest back from GHCR and
requires an exact digest match.

The workflow generates `release-metadata.json`, the SPDX 2.3 SBOM, and
`SHA256SUMS`. The metadata records the image name, registry digest,
digest-pinned reference, release tag, version, source revision, and complete
supported-platform list. GitHub also signs build-provenance and SBOM
attestations with the workflow's short-lived identity and attaches them to the
image digest in GHCR. Only after every gate succeeds does the workflow create a
prerelease draft containing the reviewed release notes and those three assets;
it never publishes the GitHub Release. The artifact job checks out the exact
commit validated before the build and revalidates the remote tag immediately
before draft creation. A rerun may resume only a matching draft with no
unexpected assets and replaces the three generated assets before requiring
their exact final set.

Protect release tags from movement or deletion and create them only from the
reviewed `main` revision intended for release. GHCR links the package to this
repository for access permissions, but its first publication is private and
does not inherit repository visibility. Consequently, the first workflow run
stops at its visibility gate after uploading the reviewed digest. An
administrator must inspect the package and digest, irreversibly change its
visibility to Public in the package settings, confirm that the digest can be
inspected without authentication, and rerun the failed workflow. Subsequent
releases require and anonymously verify public visibility before signing or
creating a draft.

Review the draft's tag, notes, immutable reference, asset checksums, SBOM, and
attestations before publishing it. Publication triggers a separate release
smoke workflow. That workflow downloads the three assets through their public
release URLs, requires the exact asset and checksum sets, validates all metadata
against the tag and source revision, anonymously inspects the public image and
its source and version OCI labels, and verifies both attestations. Both smoke
jobs pin the resolved release commit rather than continuing from a mutable tag
name. The workflow also accepts an explicit published tag through
`workflow_dispatch` for a reviewed rerun.

The tag workflow persists no registry credential. Its pinned login action
exposes the job-scoped GitHub token through the standard private Docker
authentication file used by both Skopeo and the registry-attestation steps,
then logs out in the job's post phase on both success and failure.

Consume the recorded digest rather than the version tag:

```text
ghcr.io/neodymium6/cluster-murmur@sha256:<digest-from-release-metadata>
```

After authenticating to GHCR when required, verify both attestations against
this repository:

```bash
gh attestation verify \
  oci://ghcr.io/neodymium6/cluster-murmur@sha256:<digest> \
  --repo neodymium6/cluster-murmur \
  --signer-workflow neodymium6/cluster-murmur/.github/workflows/release.yml \
  --source-digest <source-revision> \
  --source-ref refs/tags/v<version> \
  --bundle-from-oci

gh attestation verify \
  oci://ghcr.io/neodymium6/cluster-murmur@sha256:<digest> \
  --repo neodymium6/cluster-murmur \
  --signer-workflow neodymium6/cluster-murmur/.github/workflows/release.yml \
  --source-digest <source-revision> \
  --source-ref refs/tags/v<version> \
  --predicate-type https://spdx.dev/Document/v2.3 \
  --bundle-from-oci
```
