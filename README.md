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
also available. A local-only, value-free JSON Schema validation boundary,
bounded version 1 event-group, persona, binding, and routing validation, a bounded
persona-prompt file reader, and cross-category character catalog assembly are
in place. The bounded version 1 event-matcher grammar and deterministic
evaluation, event-trigger category validation, and complete startup
configuration assembly are also implemented. Matching event-trigger selection
is deterministic and bounded. Standard five-field schedule-trigger and bounded
shifted-exponential stochastic-trigger validation use a reviewed, embedded IANA
timezone snapshot without runtime updates. Pure shifted-exponential wait
sampling is deterministic through injected randomness, and pure cron next-run
calculation and stochastic active-hours evaluation have explicit DST behavior.
Pure stochastic eligibility also combines local-date daily limits with active
hours. A supervised, single-writer Ecto/SQLite repository now provides the
runtime persistence foundation. The first constrained migration and redacted
record cover restart-safe stochastic schedule state. A bounded store can restore
or initialize each configured schedule without overwriting durable state and
list available due schedules deterministically. A fixed 60-second opaque lease
can claim an exact due version, and only its redacted capability can record a
successful execution while atomically advancing the next run and daily bucket.
External execution and exactly-once delivery are not implemented. Observation
ingestion, trigger execution, LLM generation, and Discord publication are not
implemented yet. Do not deploy this revision or connect it to infrastructure,
model providers, or Discord.

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

The bootstrap escript does not carry native dependencies or migrations. After
preparing the private database directory described in the configuration guide,
build an OTP release and apply its packaged migrations explicitly after every
application instance using the database has stopped:

```bash
MIX_ENV=prod mix release
CLUSTER_MURMUR_DATABASE_PATH="$PWD/.local/cluster-murmur.sqlite3" \
  _build/prod/rel/cluster_murmur/bin/cluster_murmur eval \
  'ClusterMurmur.Release.migrate!()'
```

Application startup never runs migrations automatically.

Direnv users can approve the included `.envrc` with `direnv allow`.

## Public and private configuration

Generic schemas, examples using reserved values, tests, reusable personas, and
runtime code belong here. Real endpoints, cluster identities, credentials,
webhook URLs, private persona content, encrypted Secrets, and deployment
overlays belong in a separate private infrastructure repository.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
