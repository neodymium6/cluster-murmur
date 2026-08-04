# Cluster Murmur

Cluster Murmur is an event-driven character conversation orchestrator. It
turns read-only observations from clusters and home servers into short,
persona-driven Discord messages and bounded conversations.

## Status

Early foundation. The repository contains a minimal Elixir/OTP application,
pinned development environment, CI entry point, architecture baseline, core
domain values, external dependency behaviours, and deterministic observation
state-transition classification. Version 1 duration and common scalar
configuration validation, category-aware bounded include resolution, bounded
YAML document decoding, strict top-level manifest validation, deterministic
manifest load-plan construction, and categorized included-document decoding are
also available. A local-only, value-free JSON Schema validation boundary and
bounded version 1 event-group validation are in place. Validation and assembly
for the remaining configuration categories, observation
ingestion, persistence, triggers, LLM generation, and Discord publication are
not implemented yet. Do not deploy this revision or connect it to
infrastructure, model providers, or Discord.

## Boundary

Cluster Murmur will own:

- normalized observation ingestion;
- event extraction and deduplication;
- trigger evaluation and persona selection;
- bounded conversation orchestration;
- LLM-based expression of application-supplied facts;
- Discord publication; and
- short-term conversation memory.

Infrastructure access and diagnostic implementation remain in a read-only
observation layer such as
[`cluster-observer-mcp`](https://github.com/neodymium6/cluster-observer-mcp).
Cluster Murmur will not expose generic shell, SSH, `kubectl`, arbitrary HTTP,
or arbitrary PromQL access, and it will never perform autonomous remediation.

See [DESIGN.md](DESIGN.md) for the architecture,
[docs/configuration.md](docs/configuration.md) for the intended public
configuration contract, [docs/mvp-contract.md](docs/mvp-contract.md) for
testable MVP requirements, and [SECURITY.md](SECURITY.md) for the security
boundary.

## Development

Enter the pinned development environment:

```bash
nix develop
```

Fetch the locked Mix dependencies:

```bash
mix deps.get
```

Install repository hooks after cloning:

```bash
just init
```

Run all bootstrap checks:

```bash
just check
```

Build and inspect the bootstrap CLI:

```bash
mix escript.build
./cluster-murmur --version
```

Direnv users can approve the included `.envrc` with `direnv allow`.

## Public and private configuration

Generic schemas, examples using reserved values, tests, reusable personas, and
runtime code belong here. Real endpoints, cluster identities, credentials,
webhook URLs, private persona content, encrypted Secrets, and deployment
overlays belong in a separate private infrastructure repository.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
