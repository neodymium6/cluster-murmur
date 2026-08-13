# Deployment and operations guide

The standalone alpha starts the complete fixed runtime after validating
deployment inputs and running recovery. It remains an alpha rather than a
supported production release. Building or loading an artifact does not
authorize connecting it to infrastructure, a model provider, or Discord.

A deployment must supply and review configuration, secret mounts, storage,
network policy, probe timing, telemetry, and rollout policy.

## Build and release artifacts

The [artifact guide](operations/artifacts.md) covers the OTP release, SQLite
migration command, container archive, digest-pinned GitHub release, SBOM,
checksums, and attestations.

## Published release artifacts

The complete tagged publication and verification procedure is in the
[artifact guide](operations/artifacts.md#published-release-artifacts). This
heading preserves the established entry point for release operators.

## Runtime operations

The [runtime operations guide](operations/runtime.md) covers required container
controls, the single-writer rollout and backup model, runtime startup, metrics,
redacted logging, and graceful termination.

The [hardened Kubernetes example](../deploy/kubernetes/README.md) provides a
non-deployable public base. A separately reviewed private overlay must provide
all environment-specific values before use.
