# Cluster Murmur

Cluster Murmur is an event-driven character conversation orchestrator. It turns
read-only observations into short, persona-driven Discord messages and bounded
conversations.

## Status

Cluster Murmur is a public alpha engine. The current prerelease is
[`v0.1.0-alpha.1`](https://github.com/neodymium6/cluster-murmur/releases/tag/v0.1.0-alpha.1).

The tagged public alpha is a composable, environment-neutral engine rather than
a standalone live service. Current unreleased production builds add a
fail-closed standalone entry point using the fixed transports and runtime
assembly. Credentials, endpoints, routing, storage, and rollout policy remain
deployment-owned inputs.

Do not connect this revision to production, sensitive infrastructure, model
providers, or Discord without reviewing the exact deployment configuration,
environment, and revision.

## Capabilities

- Strict, bounded version 1 configuration loading and startup preparation.
- Deterministic observation ingestion, event extraction, deduplication, trigger
  evaluation, persona selection, and conversation planning.
- Explicit starter, responder, generation, publication, scheduling, retention,
  and restart-recovery boundaries.
- Hard limits on turns, participants, duration, LLM calls, cooldowns, response
  sizes, and stored history, with explicit no-reply outcomes and no implicit
  provider or publication retries.
- Single-writer SQLite persistence with packaged migrations and conservative
  deletion of only unreferenced events.
- Fixed OpenAI-compatible and Discord request/response boundaries, allowlisted
  facts, deterministic fallback text, disabled mentions, and redacted errors.
- Fixed production transports and a recovery-gated runtime entry point, with
  opt-in component boundaries exercised independently using fake adapters.
- Fixed value-free liveness, readiness, and startup probes for the production
  runtime without a generic management interface.
- A nondistributed OTP release, hardened OCI image definition, and CI checks for
  dependencies, source, tests, migrations, release behavior, and image metadata.

Current runtime inputs and assembly are documented in the
[configuration reference](docs/configuration.md) and
[deployment guide](docs/deployment.md). The
[public alpha boundary](docs/public-alpha.md) records the narrower historical
scope of `v0.1.0-alpha.1`.

## Safety boundary

Cluster Murmur owns normalized observation ingestion, factual event decisions,
trigger policy, bounded conversation orchestration, expression of supplied
facts, publication planning, and short-term conversation memory.

Infrastructure access and diagnostics remain in a separate read-only observer.
The engine does not expose generic shell, SSH, `kubectl`, SQL, arbitrary PromQL,
arbitrary HTTP passthrough, or autonomous remediation. Application code decides
facts and actions; an LLM may only express the facts it is given.

Observation data and prompts may be sensitive. Public configuration must not
contain credentials, webhook URLs, private endpoints, real cluster identities,
or private persona content.

## Quick start

Enter the pinned development environment and fetch locked Mix dependencies:

```bash
nix develop
mix deps.get
```

Install repository hooks and run all checks:

```bash
just init
just check
```

Run only the dependency retirement and security-advisory gate with
`just audit`.

Build the packaged OTP release:

```bash
nix build .#cluster-murmur
```

On Linux, build the Docker-compatible image archive:

```bash
nix build .#container-image
```

Building an artifact does not authorize running it against live systems. See
the [deployment and artifact guide](docs/deployment.md) for migrations, storage,
container controls, and deployment-owned inputs.

## Documentation

Use the [documentation index](docs/README.md) to choose the right level of
detail. The main references are:

- [Public alpha boundary](docs/public-alpha.md)
- [Configuration reference](docs/configuration.md)
- [Deployment and artifact guide](docs/deployment.md)
- [System design](DESIGN.md)
- [MVP runtime contract](docs/mvp-contract.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)
- [Architecture decisions](docs/adr/)

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
