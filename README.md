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
evaluation share a bounded recursive event-value boundary. Event-trigger
category validation and complete startup
configuration assembly are also implemented. Matching event-trigger selection
is deterministic and bounded behind one shared exact runtime trigger validator.
A pure adapter evaluates an injected durable cooldown projection without
executing actions, and a redacted pure plan rechecks both matching and cooldown
eligibility before later orchestration. A constrained trigger-execution record
defines the durable lifecycle, and a narrow immediate transaction starts it
only for an identical committed event, a new trigger/event pair, and an expired
durable cooldown. Exact compare-and-set transitions finish a started execution
once as completed or failed without changing cooldown state. A bounded
read-only path lists incomplete starts for later recovery policy, and all loaded
execution consumers share one exact runtime validator. A pure classifier marks
loaded starts as abandoned or recent relative to an injected cutoff, and a
narrow CAS closes abandoned starts as interrupted without retrying them. A
shared fail-closed validator now bounds exact runtime conversation metadata and
rejects untyped message projections before conversation persistence. A fixed,
constrained conversation lifecycle record and migration now provide redacted
durable metadata without generic repository access. A narrow transaction starts
that lifecycle once for an existing validated event and returns only an exact
redacted record. Exact compare-and-set transitions finish an active conversation
once as completed, cancelled, or failed. A bounded read-only path lists exact
incomplete records for later recovery policy. Typed generated messages now have
a redacted fail-closed boundary for IDs, origin, content, publication identity,
UTC time, and bounded conversation projections. A constrained message record and
packaged migration now persist that fixed shape without generic store access.
Exact loaded records share a fail-closed validator before store use. A narrow
transaction appends an unpublished message only for an exact active conversation
while advancing its turn and LLM-call counters atomically. A separate one-way
transaction records a globally unique Discord publication ID without changing
message facts. An exact read validates durable turn correlation and returns only
the latest 12 conversation messages in chronological order. Terminal transitions
also reject completion instants before the latest committed message. A separate
indexed read excludes the current conversation and returns only the latest six
currently published persona messages generated at or before an injected UTC
cutoff. A fixed redacted persona-cooldown record and packaged migration preserve
the latest spoken instant and a correlated UTC selection deadline. Loaded
cooldowns pass through one exact fail-closed validator before store use. A
separate constrained redacted event record, packaged migration, and narrow
idempotent insert store persist immutable events without exposing generic
queries or trigger deduplication policy. A primary-key-only restore path decodes
records through the same bounded domain validator. Standard
five-field schedule-trigger and bounded
shifted-exponential stochastic-trigger validation use a reviewed, embedded IANA
timezone snapshot without runtime updates. Pure shifted-exponential next-run
calculation is deterministic from a supplied UTC instant and injected
randomness, and pure cron next-run calculation and stochastic active-hours
evaluation have explicit DST behavior.
Pure stochastic eligibility also combines local-date daily limits with active
hours. A supervised, single-writer Ecto/SQLite repository now provides the
runtime persistence foundation. The first constrained migration and redacted
record cover restart-safe stochastic schedule state. A bounded store can restore
or initialize each configured schedule without overwriting durable state and
list available due schedules deterministically. A fixed 60-second opaque lease
can claim an exact due version, and only its redacted capability can record a
successful execution while atomically advancing the next run and daily bucket.
A pure adapter evaluates each available due projection against active hours and
the correctly rolled-over local-date count before claiming. A redacted pure
plan rechecks claimed execution eligibility and assembles only the supplied
event facts and completion values. External execution and exactly-once delivery
are not implemented. Observation ingestion, trigger
execution, LLM generation, and Discord publication are not implemented yet. Do
not deploy this revision or connect it to infrastructure, model providers, or
Discord.

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
