# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Runtime integration

- Fixed production UTC, monotonic-time, and bounded cryptographic-random
  adapters for later standalone runtime assembly.
- Bounded retirement of durable stochastic schedules removed from current
  configuration, suitable for fail-closed startup reconciliation.
- Fail-closed stochastic startup initialization that samples all initial runs
  before reconciling durable schedule state.
- One recovery-gated failure domain for poll, event-dispatch, recurring,
  stochastic, and event-retention schedulers.
- Redacted, bounded Cluster Observer MCP endpoint and mounted-token settings for
  later standalone transport assembly.
- Fixed, revalidated MCP 2026-07-28 Streamable HTTP request encoding for the two
  application-selected read-only observer tools.
- Bounded MCP JSON and request-scoped SSE response decoding that exposes only
  fixed structured observer results and stable transport outcomes.
- A live one-request Cluster Observer HTTP transport with verified TLS,
  incremental response limits, no redirects or retries, and conservative
  post-send failure classification.
- Explicit provider-transport classification for locally rejected malformed or
  oversized HTTP responses.
- A fixed one-request OpenAI-compatible HTTP transport with verified TLS,
  bounded parser input, and no redirects or retries.
- A transport-side validator for the exact safe Discord webhook request shape.
- A proven not-sent Discord request-validation outcome for safe publication
  failure handling.

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
