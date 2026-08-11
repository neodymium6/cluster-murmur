# Cluster Murmur v0.2.0-alpha.2

This release supersedes the immutable `v0.2.0-alpha.1` tag. That tag passed the
complete repository validation gate, but artifact preparation stopped before
publishing an image or creating a GitHub Release because the pinned container
tooling rejected runner-provided registry configuration. This revision supplies
an explicit bounded registry configuration for release and public-smoke jobs.

The application source and standalone-alpha boundary otherwise remain the same
as `v0.2.0-alpha.1`.

## Standalone runtime

- The production OTP application validates all startup inputs, opens the
  single-writer SQLite repository, runs recovery and schedule initialization,
  and only then starts the five bounded schedulers.
- Repository replacement restarts the complete gated runtime so no worker can
  resume against unprepared state.
- Production clock and cryptographic-random adapters supply only the narrow
  time and sampling operations selected by application code.
- Fixed live transports support the two application-selected read-only Cluster
  Observer MCP tools, OpenAI-compatible generation, and Discord incoming
  webhooks. They provide bounded parsing, verified TLS for HTTPS endpoints, no
  redirects, and no implicit retries after ambiguous external effects. Plain
  HTTP for an isolated local or private model provider remains an explicit
  operator-owned choice; the observer permits it only for loopback.

## Operations and packaging

- Fixed value-free liveness, readiness, and startup probes expose no generic
  management or diagnostic interface.
- Every scheduler and live transport emits fixed-cardinality Telemetry events
  and allowlisted one-line JSON lifecycle logs without prompts, responses,
  endpoints, credentials, facts, or generated content.
- The hardened Kubernetes base documents non-root execution, a read-only root
  filesystem, dropped privileges, bounded temporary storage, one private
  single-writer SQLite volume, default-deny networking, observer isolation,
  graceful termination, offline backup and restore, migrations, and rollback.
  It is intentionally not deployable until a private reviewed overlay supplies
  the environment-specific inputs.
- Tagged GitHub Releases publish one digest-addressed `linux/amd64` OCI image,
  SPDX SBOM, checksums, and signed provenance and SBOM attestations. No mutable
  version or `latest` image tag is published.
- A reviewed version-matching tag runs the full repository gate, prepares the
  artifacts, and creates a draft GitHub Release. Publishing that reviewed draft
  starts a separate smoke workflow that verifies the public asset set,
  checksums, metadata, image platform and labels, and both attestations.
- Pinned container tooling uses a repository-owned v2 registry configuration
  with no unqualified search registries instead of inheriting runner-specific
  registry defaults.

## Isolated verification

Repository CI audits the complete locked dependency graph and runs formatting,
warnings-as-errors compilation, Credo, Dialyzer, the full test suite, metadata
checks, release checks, and container checks without live infrastructure.

The release and image checks migrate an isolated SQLite database and exercise
the packaged entry point. A separate executable end-to-end example uses real
loopback observer and model HTTP transports plus the real persistence,
generation, publication, and recovery pipeline. Its final Discord effect stays
inside the test process and proves one publication followed by a duplicate-free
resumed observation.

## Deployment boundary

The repository does not contain live credentials, private endpoints, real
configuration, deployable overlays, or authorization to contact infrastructure,
a model provider, or Discord. Before any deployment, review the exact immutable
image digest, configuration, mounted secrets, network policy, storage,
retention, backup, restore, migration, rollback, probe, telemetry, and rollout
settings in the operator's private repository.

The runtime does not expose generic shell, SSH, `kubectl`, SQL, arbitrary
PromQL, arbitrary HTTP passthrough, or LLM-selected tools. Infrastructure
diagnostics remain in a separately authenticated read-only observer, and
application code remains responsible for every factual event decision.

See the [configuration reference](configuration.md),
[deployment and artifact guide](deployment.md),
[MVP runtime contract](mvp-contract.md), and [security policy](../SECURITY.md)
before evaluating a deployment.
