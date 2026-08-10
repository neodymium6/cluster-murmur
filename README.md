# Cluster Murmur

Cluster Murmur is an event-driven character conversation orchestrator. It
turns read-only observations from clusters and home servers into short,
persona-driven Discord messages and bounded conversations.

## Status

Public alpha engine. The repository contains a composable Elixir/OTP
application, pinned development environment, CI entry point, architecture
baseline, core domain values, external dependency behaviours, and deterministic
observation state-transition classification. Version 1 duration and common scalar
configuration validation, category-aware bounded include resolution, bounded
YAML document decoding, strict top-level manifest validation, deterministic
manifest load-plan construction, and categorized included-document decoding are
also available. A local-only, value-free JSON Schema validation boundary,
bounded version 1 event-group, persona, binding, routing, and LLM-provider
validation, a bounded persona-prompt file reader, and cross-category character
catalog assembly are in place. The bounded version 1 event-matcher grammar and deterministic
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
narrow store restores optional state and monotonically records newer spoken
facts with idempotent retries, exact compare-and-set, and durable revalidation. A
pure deterministic fallback emits one neutral factual template for a validated
event and revalidates the complete generated message without interpreting or
interpolating arbitrary event data. Configured personas now pass through one
exact fail-closed runtime validator that also enforces the shared cooldown
interval bound before later selection or generation. Configured bindings also
share one exact runtime boundary for their IDs, bounded candidate sets,
non-negative finite weights, and unique persona references. A pure starter
projection revalidates bounded persona and cooldown snapshots, excludes
disabled personas and active cooldowns at an injected UTC instant, and emits
redacted configured weight components in stable persona order without sampling.
A bounded selector revalidates those projections, handles empty, zero-total,
and sole-positive outcomes without randomness, and delegates only a final
stable weighted choice among multiple positive candidates. A pure conversation
budget evaluator revalidates injected UTC time and runtime state, then projects
clamped remaining turns, participant slots, duration, and LLM calls without
closing a conversation merely because its existing participant set is full. A
pure responder projection combines those limits with binding membership,
event-group relevance, cooldowns, and explicit consecutive/reentry policy,
emitting only stable redacted configured weight components before reply gating.
An independent reply gate returns an explicit reply or no-reply decision from
the bounded event-group probability and at most one injected uniform sample. A
bounded responder selector honors that gate, adds an independent weighted
no-reply outcome, and delegates only the final choice among multiple positive
validated outcomes to injected randomness. A redacted fact projection exposes
only fixed application-confirmed event fields to generation and revalidates the
actual escaped JSON representation against a 64 KiB boundary. An exact
generation context keeps an exact identity-and-instructions persona projection,
validated facts, creative framing, and at most
12 chronological history lines separate under a combined 128 KiB text bound.
A redacted provider-neutral prompt request preserves those categories as fixed
structured fields without delimiter interpolation. Raw provider text passes a
bounded deterministic normalizer that removes narrow control and redundant
speaker-label forms, then rejects unsafe URLs, network locations, mentions, or
invalid content through the shared message boundary. A pure provider-result
resolver then returns normalized LLM text or an explicit fallback decision
without exposing provider diagnostics. A bounded mounted-secret reader resolves
only validated environment-variable names to absolute regular-file targets and
returns a trimmed non-empty UTF-8 value without exposing sensitive diagnostics. A
provider-settings boundary resolves bounded OpenAI-compatible endpoint, model,
and mounted API-key values without making a network request or exposing them
through inspection. A fixed redacted OpenAI-compatible request boundary
revalidates those settings and the complete structured prompt, then encodes only
the chat-completions path, headers, JSON shape, and bounded transport options
without connecting. A bounded OpenAI-compatible response decoder extracts only
one string message from a single choice and maps status families to stable error
classes without exposing raw provider diagnostics. A narrow provider adapter
revalidates that fixed request, invokes one injected transport exactly once,
and returns only decoded content or stable errors without retrying. A Discord
settings boundary likewise resolves exactly one
bounded incoming-webhook credential from the validated default route, restricts
it to Discord's fixed HTTPS URL shape, and performs no publication. A fixed
redacted runtime-settings aggregate loads both provider and webhook deployment
settings before external startup without making a connection. A fail-closed
startup preparation boundary now loads complete public configuration first and
returns both values only after exact revalidation, without starting workers. A
fixed Discord payload boundary combines an unpublished message with its exact
enabled persona, enforces API character limits, and always disables mention
parsing. A pure durable-state publication planner skips known published records
and emits only redacted validated plans for unpublished records, while leaving
ambiguous external outcomes to an explicit later recovery policy. A
fixed redacted observation entity-state value and SQLite record now preserve
bounded debounce progress and latest facts behind composite source/subject
identity constraints; loaded validation and monotonic store access reject stale
or conflicting updates. A separate constrained redacted event record, packaged
migration, and narrow idempotent insert store persist immutable events without
exposing generic queries or trigger deduplication policy. A primary-key-only
restore path decodes records through the same bounded domain validator. One
atomic observation-ingestion store now restores prior state, delegates the
factual debounce and event decision to the pure planner, and commits the next
state with its optional event or rolls both back. A closed state-tracking
configuration value now validates fixed default failure and success counts plus
at most 256 complete source or source-subject overrides. It resolves exact
subject, then source, then default precedence to the only runtime debounce-policy
shape without exposing selectors through inspection. The bounded poller
validates the complete mapping before observer access and applies the selected
policy only after validating each correlated observation. The startup manifest
and complete public configuration normalize the mapping before any worker
construction. Standard
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
event facts and completion values. Configured schedule and stochastic event
templates now project to bounded immutable events whose identity and occurrence
time remain identical across retries of one scheduled version and exact
template; template drift preserves the ID so persistence can fail closed rather
than accept a duplicate. A narrow SQLite transaction now commits one exact
projected stochastic event, its durable dispatch handoff, and its claimed
next-run state, rolling back the attempt on conflict. One explicit bounded
cycle now traverses
100-record cursor pages up to the 256-trigger configuration bound, skips
ineligible policies without claiming, and runs each eligible schedule through
claim, planning, projection, and atomic commit in durable order. Scheduling and
event-trigger dispatch remain separate: an opt-in worker can now schedule those
cycles without overlap but is not installed in the public application tree,
while a dedicated 100-entry, opaque-lease outbox now provides the durable
event-dispatch handoff. Each successful stochastic commit now inserts the
event, enqueues that handoff, and advances its claimed schedule in one SQLite
transaction. A pure planner now correlates up to 100 available handoffs with
their restored immutable events and caps current event-trigger matches at 256
before any claim. The fixed starter-only and bounded-conversation consumers can
preflight that durable plan without changing their authorization-free input
checks. One explicit cycle can now preflight a complete batch, claim each entry,
run matching fixed consumers in stable order, and complete only unmatched or
fully terminal handoffs while retaining failed claims for lease-based retry.
An opt-in worker can schedule those cycles without overlap while retaining only
redacted aggregate status. No event-dispatch scheduler is installed
automatically.
The startup configuration now normalizes bounded event dedupe-window and
retention durations. A pure evaluator defines first acceptance, exact retry,
active suppression, and expiry-boundary behavior. A constrained redacted table
holds durable markers, and trigger authorization now advances those markers in
the same transaction as execution starts across poll and durable dispatch.
A pure planner derives one exact retention cutoff from the normalized policy
and an injected UTC instant without reading storage or a clock. A narrow store
can prune at most 100 dedupe markers at or before that cutoff without returning
their values. One explicit cycle validates the complete configuration and an
injected UTC instant before invoking one marker batch followed by one event
sweep from the same plan, and returns only aggregate counts. Referenced-lifecycle retention and
deployment wiring remain future work. An opt-in worker can schedule these
cycles without overlap and retains only redacted aggregate status; it is not
installed automatically.
A separate bounded sweep can scan at most 100 expired events, delete only
records with no trigger-execution, conversation, dispatch, or dedupe-marker
reference, and advance a durable redacted cursor past referenced rows. It does
not cascade lifecycle data.
Observer
target responses now pass a closed 256-entry and 64 KiB
identity catalog that rejects duplicates and sorts accepted redacted targets
before polling. One injected, sequential poll lists that catalog once, observes
each accepted identity once, and sends only matched normalized observations
through atomic ingestion while collecting validated events and stable partial
failures. A fixed MCP observer client exposes only
target-list and cluster-health operations through a bounded redacted transport.
One matched event trigger can now cross its
pure planner and atomic start store through a redacted authorization boundary;
matching triggers can be authorized sequentially in one deterministic bounded
batch with stable partial outcomes. One exact authorization can now resolve
its trigger and binding against the complete runtime configuration, project a
supplied bounded cooldown snapshot, select one eligible starter, and produce a
redacted pristine conversation plan. A narrow action boundary now revalidates
that exact plan, then atomically persists its pristine conversation and
compare-and-set completes the durable trigger execution. It returns only a
correlated redacted one-use start capability. A pure starter-generation planner
now projects that capability into separated persona instructions, allowlisted
event facts, fixed creative framing, empty first-turn history, and one exact
provider-neutral request. A narrow starter executor now calls one injected
provider exactly once, normalizes accepted output, and resolves every provider
or output failure to the fixed deterministic fallback before returning a typed
unpublished message. A narrow persistence boundary now atomically appends that
message and advances the durable conversation turn and LLM-call counters once,
returning only exact correlated loaded capabilities. A pure starter-publication
planner now resolves the exact selected persona from current configuration and
builds a fixed mention-disabled Discord payload from the committed message and
current webhook settings. A narrow boundary now records an exact durable
publication attempt for that plan before any external request. Dispatch claim,
publication transport execution, and terminal outcome recording now cross one
narrow boundary: it revalidates the started capability, delegates one durable
claim and injected publisher call, and atomically records exact success,
classified failure, or an ambiguous effect without retrying. A successful
terminal capability now records the exact selected persona's restart-safe
cooldown from publication completion and current bounded policy; failed or
ambiguous outcomes cannot update it. The existing reply gate now closes
the exact starter conversation on explicit no reply, while an explicit reply
remains nonterminal for later responder orchestration. One narrow coordinator
now composes an already authorized event through those boundaries. Its
integration test uses real SQLite stores with a fake observer, generation, and
Discord transports, proving that one observed transition reaches deterministic
no-reply completion without returning event facts or reusable authorization
capabilities from the cycle boundary. Generation still supplies only the
allowlisted event facts to the explicitly configured model provider.
An opt-in conversation mode derives a fresh finite responder schedule from
bounded relative offsets, preflights every fixed dependency before observation,
and can progress a proven starter continuation through responder completion.
The opt-in GenServer schedules poll cycles without overlap; it has no live
defaults and is not installed in the application tree automatically. Bounded
restart recovery validates every abandoned record before mutation, marks open
publication outcomes ambiguous without retry, and fails interrupted
conversations and trigger executions through existing CAS boundaries. The
poll-only supervisor gates its scheduler on complete recovery at one injected
UTC instant. When poll and event dispatch are both enabled, a shared opt-in
supervisor validates and recovers once before starting either scheduler. A
failure of either stops both, so parent-managed replacement cannot run global
recovery against live sibling work. Both supervisors fail closed on a saturated
recovery page and remain absent from the default application tree. Do not deploy
this revision or connect it to infrastructure, model providers, or Discord
without explicit review of that private assembly.

### Public alpha boundary

The public alpha is the environment-neutral engine, not a standalone live
deployment. It includes the bounded domain and persistence boundaries, explicit
runtime cycles, opt-in schedulers, restart recovery, release packaging, and
fake-adapter integration coverage. The default OTP application intentionally
starts only the repository.

Live MCP, model-provider, and Discord transports, concrete endpoints and
credentials, and assembly of the opt-in supervisors and workers remain
deployment-owned. Event retention remains conservative: the public engine
deletes only events that have no lifecycle references and does not cascade
through conversations, executions, dispatches, or dedupe records.

The exact completion criteria and deferred standalone-service work are recorded
in [docs/public-alpha.md](docs/public-alpha.md).

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
testable MVP requirements, [docs/public-alpha.md](docs/public-alpha.md) for the
public alpha boundary, and [SECURITY.md](SECURITY.md) for the security boundary.

## Development

Enter the pinned development environment:

```bash
nix develop
```

Build the immutable production release with:

```bash
nix build .#cluster-murmur
```

The release is intentionally nondistributed and contains no generated Erlang
cookie. It still requires an approved absolute `CLUSTER_MURMUR_DATABASE_PATH`
whose existing parent directory is private. Runtime configuration, secrets,
external transports, and worker assembly remain deployment-owned inputs.

On Linux, build the Docker-compatible image archive with:

```bash
nix build .#container-image
docker image load -i result
```

The scratch-based image uses the OCI image configuration and standard OCI
labels, runs as numeric user and group `65532:65532`, starts the nondistributed
release through Tini, declares no ports or volumes, and contains no deployment
configuration or credentials. The flake check extracts the image, verifies this
metadata and complete runtime closure, removes write permission except from the
two intended writable paths, and smoke-runs the extracted Tini and release
against an isolated temporary database. This archive-level check does not apply
container-runtime mount, identity, or privilege controls. Running the image
requires all of the following deployment-owned controls:

- make the root filesystem read-only;
- drop every Linux capability and disable privilege escalation;
- mount a size-bounded private tmpfs at `/tmp`, owned by `65532:65532`; and
- mount private persistent storage at `/var/lib/cluster-murmur`, owned by
  `65532:65532`, then set `CLUSTER_MURMUR_DATABASE_PATH` to an absolute path
  below that directory.

For example, an equivalent Docker hardening profile includes `--read-only`,
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, and
`--tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,uid=65532,gid=65532,mode=0700`.
The database bind mount and all remaining runtime settings are private
deployment inputs. Loading the archive does not authorize running it against
live infrastructure or external services.

Fetch the locked Mix dependencies:

```bash
mix deps.get
```

Install repository hooks after cloning:

```bash
just init
```

Run all repository checks:

```bash
just check
```

Run only the locked-dependency retirement and security-advisory gate with:

```bash
just audit
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
