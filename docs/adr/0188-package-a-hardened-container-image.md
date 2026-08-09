# 0188. Package a hardened container image

Date: 2026-08-09

## Status

Accepted

## Context

The immutable production release needs a portable Linux artifact for later
deployment. An image can set its process identity and startup command, but it
cannot require runtime-only controls such as a read-only root filesystem,
capability removal, or the ownership and policy of mounted storage.

The release writes temporary launch state and one SQLite database. Treating the
container root as writable or storing that database in an anonymous image
volume would hide important deployment requirements and weaken recovery and
backup ownership.

## Decision

Expose a reproducible, scratch-based, Docker-compatible layered image archive
on Linux as the flake's `container-image` package. Use the OCI image
configuration semantics and standard OCI labels. Run the release as the fixed
numeric identity `65532:65532`, use Tini only for signal forwarding and child
reaping, and retain the release's nondistributed Erlang policy. Include no
configuration, credentials, endpoint defaults, declared network ports, or
volume declarations.

Require deployments to provide all of these controls:

- a read-only root filesystem;
- all Linux capabilities dropped and privilege escalation disabled;
- a size-bounded private tmpfs at `/tmp`, owned by `65532:65532`;
- a private persistent mount at `/var/lib/cluster-murmur`, owned by
  `65532:65532`; and
- an absolute `CLUSTER_MURMUR_DATABASE_PATH` below that persistent mount.

Keep filesystem and capability policy deployment-owned because image metadata
cannot enforce it. Verify the archive metadata, numeric user, exact entrypoint,
command, environment allowlist, absence of ports and volumes, fixed OCI labels,
account files, writable-directory placeholders, and executable closure without
requiring a container daemon.

## Consequences

`nix build .#container-image` produces a Docker-loadable image archive for the
current Linux system. It is not an OCI image-layout archive. The image does not
claim to be safe under runtime defaults: an operator must satisfy the documented
hardening contract and privately inject configuration, secrets, and storage.
Multi-architecture manifests, OCI archive conversion, and registry publication
remain deployment or release-pipeline concerns.
