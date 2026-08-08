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
configuration value now validates the fixed failure and success counts and
projects them to the only runtime debounce policy shape. The startup manifest
and complete public configuration carry either those defaults or one exact
explicit mapping before any worker construction. Standard
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
projected stochastic event together with its claimed next-run state, rolling
back either side on conflict. External stochastic worker timing and
event-trigger dispatch are not implemented. Event retention and dedupe-window
policy also remain future work. Observer target responses now pass a
closed 256-entry and 64 KiB identity catalog that rejects duplicates and sorts
accepted redacted targets before polling. One injected, sequential poll lists
that catalog once, observes each accepted identity once, and sends only matched
normalized observations through atomic ingestion while collecting validated
events and stable partial failures. A fixed MCP observer client exposes only
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
conversations and trigger executions through existing CAS boundaries. An
opt-in supervisor now gates scheduler startup on complete recovery at one
injected UTC instant, fails closed on a saturated recovery page, and reruns that
gate through its parent after scheduler termination. It also remains absent
from the default application tree. Do not deploy this revision or connect it to
infrastructure, model providers, or Discord without explicit review of that
private assembly.

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
