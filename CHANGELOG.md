# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## [0.2.0-alpha.2](docs/release-notes-v0.2.0-alpha.2.md) - 2026-08-11

### Release automation

- Isolated pinned container tooling from runner-provided registry
  configuration so tagged artifact preparation behaves consistently across
  supported GitHub-hosted runners.
- Superseded the immutable `v0.2.0-alpha.1` tag after its artifact-preparation
  run stopped before publishing an image or creating a GitHub Release.

## [0.2.0-alpha.1](docs/release-notes-v0.2.0-alpha.1.md) - 2026-08-11

### Runtime and transport integration

- Fixed production UTC, monotonic-time, and bounded cryptographic-random
  adapters used by the standalone runtime assembly.
- Bounded retirement of durable stochastic schedules removed from current
  configuration, suitable for fail-closed startup reconciliation.
- Fail-closed stochastic startup initialization that samples all initial runs
  before reconciling durable schedule state.
- One recovery-gated failure domain for poll, event-dispatch, recurring,
  stochastic, and event-retention schedulers.
- Redacted, bounded Cluster Observer MCP endpoint and mounted-token settings for
  the standalone transport assembly.
- Fixed, revalidated MCP 2026-07-28 Streamable HTTP request encoding for the two
  application-selected read-only observer tools.
- Bounded MCP JSON and request-scoped SSE response decoding that exposes only
  fixed structured observer results and stable transport outcomes.
- A live one-request Cluster Observer HTTP transport with verified TLS for
  remote endpoints, loopback-only plain HTTP, incremental response limits, no
  redirects or retries, and conservative post-send failure classification.
- Explicit provider-transport classification for locally rejected malformed or
  oversized HTTP responses.
- A fixed one-request OpenAI-compatible HTTP transport with verified TLS for
  HTTPS endpoints, bounded parser input, and no redirects or retries; plain
  HTTP remains an explicit choice for isolated local or private providers.
- A transport-side validator for the exact safe Discord webhook request shape.
- A proven not-sent Discord request-validation outcome for safe publication
  failure handling.
- A fixed one-request Discord webhook HTTPS transport with bounded response
  processing and conservative post-dispatch outcome classification.
- Observer MCP settings included in the redacted, fail-closed startup settings
  aggregate alongside provider and webhook settings.
- Network-free construction of the fixed observer client, model provider,
  publisher, and their startup-captured narrow live transports.
- Explicit bounded startup settings for all five runtime scheduler cadences,
  with busy-loop lower limits and no live defaults.
- Stable bounded restoration of current durable cooldowns for configured
  personas without generic persistence listing.
- Per-poll refresh of durable persona cooldowns before observation or speaker
  selection, with fail-closed storage handling.
- Per-dispatch refresh of durable persona cooldowns before outbox reads or
  claims, shared by starter-only and bounded-conversation consumers.
- Explicit bounded responder schedule timing settings loaded during startup,
  with ordered per-turn delays and no live defaults.
- Pure finite responder-schedule construction from conversation bounds,
  deployment timings, and explicit narrow transports.
- Fixed, cross-validated production starter and responder adapter bundles with
  no deployment-selected persistence or policy modules.
- Effect-free assembly and preflight of shared production poll and durable
  event conversation contexts from one validated startup value.
- Validated production poll and durable event scheduler options with fixed
  clock, cycle, ingestion, and interval-derived first-run delays.
- Validated recurring, stochastic, and retention scheduler options with fixed
  cycles, system clock and randomness, and interval-derived first-run delays.
- Effect-free assembly and preflight of the fixed recovery-gated five-scheduler
  production supervisor options.
- A fail-closed production OTP entry point that prepares bounded deployment
  inputs, starts SQLite first, and gates all five runtime schedulers behind
  recovery and schedule initialization, including after repository replacement.

### Operations and packaging

- Fixed value-free liveness, readiness, and startup HTTP probes with a monitored
  lease acquired after recovery and released before runtime shutdown drains.
- Fixed-cardinality scheduler and normalized external outcome Telemetry events
  with matching allowlisted JSON lifecycle logs in production.
- A non-deployable hardened Kubernetes base and runbook for single-writer
  rollout, offline backup/restore, migration rollback, and observer isolation.
- Protected tagged-release publication for one digest-pinned `linux/amd64`
  image with SPDX SBOM, checksums, and signed provenance attestations.
- Tag-driven release validation and artifact publication that prepares a draft
  GitHub Release for human review, followed by a separate public-distribution
  smoke workflow when the draft is published.

### Verification

- An executable isolated end-to-end example covering real loopback observer and
  model transports, SQLite lifecycle persistence, publication-once, and safe
  resumed polling after startup recovery.

## [0.1.0-alpha.1] - 2026-08-11

### Added

- A bounded, environment-neutral observation-to-conversation engine with
  deterministic event, trigger, conversation, generation, publication,
  scheduling, recovery, and retention boundaries.
- Strict versioned YAML configuration loading, bounded includes, schema and
  semantic validation, mounted-secret references, and exact startup-input
  preparation.
- Single-writer SQLite persistence with packaged migrations, optimistic
  lifecycle transitions, durable cooldowns, publication claims, dispatch
  leases, restart recovery, and conservative unreferenced-event retention.
- Opt-in poll, event-dispatch, stochastic, recurring, conversation, recovery,
  and retention runtime components with fake-adapter integration coverage.
- Fixed OpenAI-compatible request and response boundaries, deterministic
  factual fallback generation, mention-disabled Discord payloads, and stable
  redacted external-error classes.
- A nondistributed OTP release and hardened OCI image definition with
  environment-neutral release, migration, metadata, runtime-closure, and
  extracted-entrypoint smoke checks.
- Pinned Nix and Mix dependency graphs, dependency retirement and security
  advisory auditing, Credo, Dialyzer, repository metadata, and cross-system
  evaluation gates.

### Security

- Observation data, prompts, persisted values, logs, and external outcomes use
  bounded allowlists, exact runtime validation, redacted inspection, and stable
  error normalization.
- The engine does not expose generic shell, SSH, `kubectl`, SQL, arbitrary
  PromQL, arbitrary HTTP passthrough, or autonomous remediation capabilities.

### Known limitations

- This prerelease is the composable public alpha engine, not a supported
  standalone service or an authorization to connect to live infrastructure.
- The default OTP application starts only the repository. Live transports,
  credentials, runtime assembly, health integration, deployment manifests, and
  rollout policy remain deployment-owned.
- Event cleanup deletes only unreferenced events and does not cascade through
  referenced lifecycle records.

[0.1.0-alpha.1]: https://github.com/neodymium6/cluster-murmur/releases/tag/v0.1.0-alpha.1
