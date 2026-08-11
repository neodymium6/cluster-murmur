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
