# Configuration Reference

## Status and scope

This document defines the public configuration contract targeted by the MVP.
The runtime is at the early foundation stage, so examples describe intended
behavior unless a capability is explicitly identified as implemented.

Configuration controls observations, event policy, personas, bindings,
triggers, generation limits, and outbound routing. It must never contain
credentials, webhook URLs, private endpoints, or environment-specific
identifiers.

## Loading model

Configuration uses YAML 1.2. Bounded document decoding, strict top-level
manifest validation, duration and common scalar validation, bounded include
resolution, composition of those manifest stages into a load plan, and bounded
decoding of the included YAML documents are implemented. A value-free Draft 7
validation adapter for application-owned schemas and bounded event-group, persona,
binding, routing, LLM-provider, and event-trigger validation, cross-category
character catalog assembly, and complete startup configuration assembly are
implemented. The top-level startup value also normalizes fixed state-tracking,
conversation, and event-policy defaults or one exact explicit mapping for each.
A fixed
top-level file includes files by category:

```text
config/
|-- cluster-murmur.yaml
|-- event-groups.yaml
|-- routing.yaml
|-- personas/
|   |-- observer.yaml
|   `-- caretaker.yaml
|-- bindings/
|   |-- monitoring.yaml
|   `-- social.yaml
|-- triggers/
|   |-- observations.yaml
|   |-- schedules.yaml
|   `-- stochastic.yaml
`-- prompts/
    |-- observer.md
    `-- caretaker.md
```

The top-level file declares the configuration version and includes:

```yaml
version: 1

state_tracking:
  failures_required: 2
  successes_required: 2

event_policy:
  dedupe_window: 5m
  retention: 90d

llm:
  provider: openai_compatible
  base_url_env: CLUSTER_MURMUR_LLM_BASE_URL
  model_env: CLUSTER_MURMUR_LLM_MODEL
  api_key_file_env: CLUSTER_MURMUR_LLM_API_KEY_FILE
  timeout: 20s
  max_output_tokens: 300

includes:
  event_groups:
    - event-groups.yaml
  personas:
    - personas/*.yaml
  bindings:
    - bindings/*.yaml
  triggers:
    - triggers/*.yaml
  routing:
    - routing.yaml
```

The version 1 manifest requires exactly `version`, `llm`, and `includes`, and
optionally accepts exact `state_tracking`, `conversation_defaults`, and
`event_policy` mappings. Omitting `event_policy` uses a five-minute dedupe
window and 90-day retention. Both event durations must be positive, no longer
than 365 days, and retention must be at least the dedupe window. Trigger
authorization enforces the dedupe window; retained data is not yet deleted.
Omitting `state_tracking` uses the fixed two-failure and two-success defaults.
All five include categories must be present, even when a category has no
patterns. Every other field or category is invalid. Category values are lists
of strings. The 64-pattern limit applies to the sum across every category, not
separately to each resolver call.

Relative paths are resolved from the directory containing the top-level file.
Version 1 include paths use portable ASCII characters and support only
non-recursive `*` globs. Absolute paths, `..`, other glob operators, symlink
loops, non-file targets, and canonical targets outside the configuration root
are invalid. A top-level configuration may declare at most 64 include patterns;
each pattern is at most 512 bytes and must match at least one file; resolution
rejects after wildcard directory listings cumulatively return more than 1,024
entries, and the combined result is limited to 256 unique files. Erlang/OTP
materializes each individual directory listing before this check, so the
trusted configuration tree must not contain unbounded directories. Portable
filename rules also apply to canonical targets. Safe symlinks inside the root
are canonicalized with a limit of 40 symlink expansions per resolved path. The
configuration tree must be trusted and read-only until loading finishes.
Results are deduplicated and sorted, so glob expansion order has no semantic
meaning. Identical patterns are evaluated once when shared by categories. The
1,024 inspected-entry and 256 unique-file budgets apply across the complete
manifest, not independently to each category. The manifest loader first returns
the validated manifest and these canonical paths as a categorized load plan.
Its next stage decodes each unique included YAML file once, retains its source
path for later relative-reference handling, and preserves the category lists.
The generic document-loading stage does not apply category-specific schemas or
semantic validation. Event-group documents can then be structurally validated
and combined into a redacted configuration set. Failures
identify the top-level document, manifest, includes, or included-document stage
without including rejected values or paths. Configuration structs omit include
patterns, paths, and decoded values from their inspection output. Configuration
is loaded once at startup; hot reload is outside the MVP.

Each YAML file is limited to 256 KiB and must contain exactly one mapping-rooted
document. Keys must be strings. Decoding accepts only strings, nulls, booleans,
integers, finite floats, sequences, and mappings. It rejects duplicate keys,
anchors, aliases, tag directives, YAML versions other than 1.2, scalars larger
than 16 KiB, more than 4,096 nodes, or collection nesting deeper than 16 levels.
Prompt files are loaded separately from YAML. A prompt reference is a portable
relative path of at most 512 bytes, resolved from the canonical persona source
file. Parent components may address a sibling directory, but the canonical
regular-file target must remain inside the configuration root and use portable
ASCII path components. Prompt files must be non-empty, valid UTF-8, and no
larger than 64 KiB. Canonical resolution follows at most 40 symlinks. Prompt
errors do not include paths or contents.

## Validation

After the top-level manifest is decoded and validated, category configuration
validation has two fail-closed stages:

1. JSON Schema validates document structure and rejects unknown fields.
2. Elixir semantic validation resolves references and validates values that
   JSON Schema cannot safely establish.

Version 1 schemas use JSON Schema Draft 7, are compiled from application source,
and cannot use `$ref`, `id`, or `$id`. Operator configuration cannot supply a
schema, filesystem path, or schema resolver. Unknown formats are ignored
locally instead of invoking a globally configured callback. The
`contentEncoding` and `contentMediaType` keywords are unsupported because their
implementation delegates document data to a global decoder. Validation errors
never include the library's detailed paths or rejected values.
Schema source must be a proper JSON-compatible tree with string object keys,
and compiled validators are rechecked before use rather than trusting a public
struct value.

Startup must fail before external connections or publication when any of the
following is found:

- an unsupported configuration version;
- an unknown field;
- a duplicate ID within its ID namespace;
- a reference to an unknown persona, binding, or event group;
- a missing included file or an include that resolves to no required files;
- a malformed duration, cron expression, clock time, or IANA timezone;
- a negative weight or probability outside the inclusive range `0.0..1.0`;
- a stochastic mean interval that cannot produce a valid schedule;
- an unreadable, oversized, empty, or insecurely referenced secret file; or
- a configuration that would remove a required conversation bound.

IDs are portable ASCII strings of at most 16 KiB suitable for persistence keys.
They start with an ASCII letter or digit and continue with ASCII letters,
digits, `.`, `_`, or `-`. Human-facing fields such as `display_name` may use Unicode. Durations use
an integer followed by one of `ms`, `s`, `m`, `h`, or `d`. Times use 24-hour
`HH:MM` notation. Timezones use IANA names such as `Asia/Tokyo` or `Etc/UTC`.

## Database path

The supervised SQLite repository uses an in-memory database only in the test
environment. Production requires `CLUSTER_MURMUR_DATABASE_PATH` to contain a
non-empty absolute path of at most 4,096 bytes. Development accepts the same
override and otherwise uses `.local/cluster-murmur.sqlite3` below the repository
root. `:memory:` is rejected outside tests even when supplied through the
environment.

At repository startup, the database's immediate parent directory must already
exist with mode `0700`; missing or more permissive directories are rejected.
A missing database file is created inside that private directory with mode
`0600`, while an existing file must already have that exact mode. An immediate
parent or database symlink and non-directory or non-regular targets are
rejected. The private directory also prevents other local users from accessing
SQLite WAL and shared-memory files created beside the database.

The complete path ancestry is trusted deployment input. Every ancestor must be
controlled by the operator, contain no symlink components, and be unwritable by
untrusted principals. The startup checks use pathname-based filesystem calls,
and the current SQLite adapter does not expose a race-safe no-follow open.
Consequently, these checks reject accidental unsafe configuration but do not
defend against a principal that can rename or replace an ancestor or path while
startup is in progress. Do not place the database below a shared writable
directory. Operators must prepare the private development or PVC mount
directory before startup.

Prepare the default development directory from the repository root with:

```bash
mkdir -p .local
chmod 0700 .local
MIX_ENV=prod mix release
CLUSTER_MURMUR_DATABASE_PATH="$PWD/.local/cluster-murmur.sqlite3" \
  _build/prod/rel/cluster_murmur/bin/cluster_murmur eval \
  'ClusterMurmur.Release.migrate!()'
```

The repository has one connection, uses immediate transactions, enables foreign
keys and WAL mode, and waits at most five seconds for a busy database. SQL query
logging and sensitive connection-error details are disabled. These connection
settings and the first stochastic-schedule schema and migration are implemented.
The first domain store transaction restores an existing stochastic schedule or
inserts its initial next run without replacing durable state. Its read-only due
query returns at most 100 available redacted records in deterministic order. A
separate immediate transaction can claim one exact due version through an
internally generated 256-bit capability with a fixed 60-second expiry. Only the
matching claim, executed and recorded within its lease interval, can clear the
lease, advance the next run, and update its local-date counter atomically. Lease
claim candidates are evaluated purely against active hours and a persisted
counter normalized to the calculated current local date. Renewal, early
release, external execution, exactly-once delivery, other schemas and stores,
automatic migration execution, event-record deletion, and retention-worker
deployment remain later stages. A
separate bounded event store validates complete events before storage, inserts
immutable event IDs idempotently, and rejects conflicting reuse without
replacing committed facts. Its primary-key-only read restores at most one event
through the shared bounded validator. The startup configuration normalizes
bounded event retention and dedupe-window durations, and trigger authorization
enforces durable dedupe markers. Event listing, event-record retention, and
retention-worker deployment remain later stages. A
narrow observation-ingestion transaction restores prior entity state, applies
the pure debounce and event plan, and commits the next state with its optional
event atomically. It performs no observer call or trigger action.

The implemented poll runtime composes one fixed read-only observer poll, atomic
ingestion, deterministic event-trigger matching, durable authorization,
bounded starter generation, and claimed Discord publication. Its explicit
conversation mode additionally projects a finite responder schedule from
validated relative offsets and runs only through correlated fixed adapters.
The periodic scheduler is opt-in: the public application supervision tree does
not construct an observer, external transports, secrets, timing, or an interval
by default. A deployment must build validated scheduler options in its private
assembly and explicitly supervise the child. The scheduler completes one cycle
before creating the next timer and rejects stale or injected timer messages.

Restart recovery is also explicit. It loads at most 100 abandoned trigger
executions, active conversations, and open publication attempts per collection;
validates every record before the first mutation; then fails internal work and
marks uncertain publications ambiguous. It never retries a provider call or
Discord publication. Operators choose the UTC abandonment cutoff and completion
instant. The opt-in recovered poll supervisor reads one injected storage-UTC
instant, uses it for both values, and starts its fixed scheduler child only when
every bounded recovery mutation succeeds and no collection fills its 100-record
page. When poll and event dispatch are both enabled, the recovered runtime
supervisor validates both schedulers and exact recovery stores before reading
that shared clock, recovers once, then starts both. Termination of either worker
closes the shared supervisor and stops its sibling, so a parent-managed
replacement cannot run global recovery against live work. A full page requires
another startup pass to prove that no residual work remains. These boundaries
remain outside the public application tree, so private deployment assembly must
construct and supervise them explicitly.

`ClusterMurmur.Release.migrate!/0`, invoked after every application instance
using the database has stopped, is the only application migration operation. It
applies packaged migrations to the fixed configured repository, is safe to
repeat, and reports only a generic failure. It rejects a running application or
repository in its own evaluation VM; this local check cannot detect a separate
release VM. It does not perform rollback or accept caller-selected repositories
or paths. The bootstrap escript is version-only because native libraries and
migration files require an extracted release filesystem.

Generic Ecto URL configuration is rejected because URL parsing occurs after the
repository callback and could otherwise replace the validated database path or
connection bounds.

## Runtime defaults

Defaults belong to the versioned schema. Implementations must not silently
change them within configuration version 1.

```yaml
state_tracking:
  failures_required: 2
  successes_required: 2

conversation_defaults:
  max_turns: 3
  max_participants: 2
  max_duration: 5m
  max_llm_calls: 3
  allow_same_persona_consecutively: false
  allow_persona_reentry: true
  responder_selection:
    no_reply_weight: 1.0
    random_jitter: 0.2

event_policy:
  dedupe_window: 5m
  retention: 90d

memory:
  current_conversation_messages: 12
  recent_persona_messages: 6
  recent_channel_messages: 8
  maximum_context_tokens: 2000

retention:
  entity_states: forever
  conversations: 30d
  messages: 30d
  trigger_executions: 30d
  llm_payloads:
    enabled: false
    retention: 7d
```

`state_tracking` may be overridden for a known source or subject. Overrides use
the same bounded positive-integer fields and are resolved by semantic
validation. The exact override syntax will be added to version 1 before the
observation adapter is considered complete.

The startup manifest and complete configuration normalize the two fixed default
counts or an exact explicit mapping to the runtime debounce policy. Override
precedence remains later configuration work.

The startup manifest and complete configuration also normalize the exact event
policy shown above. These values are application-owned limits; they do not add
storage passthrough or configure a cleanup worker. A pure evaluator defines the
dedupe decision and stable suppression reason, and a constrained table can hold
exact redacted markers. Trigger authorization atomically enforces marker
replacement with execution start across poll and durable dispatch. Poll results
retain the stable reason and durable dispatch reports a redacted aggregate
suppression count. The broader `retention` mapping remains an intended future
contract and does not duplicate the implemented event retention field.

The normalized event retention duration can be projected into one exact cutoff
from an injected canonical UTC instant. A fixed store operation can use only
that exact plan to delete at most 100 expired dedupe markers without returning
their values. An explicit runtime cycle validates the complete configuration
and injected instant before planning and invoking exactly one fixed store
batch. It returns only the aggregate count; it does not repeat cleanup, delete
immutable events, or read a clock. An opt-in worker can supply a validated UTC
clock and schedule these cycles without overlap while retaining only redacted
aggregate status. No retention worker is installed automatically.

The event table's retention order and every child-table event reference are
indexed for a later bounded event-record cleanup store. These indexes do not
enable deletion, cascade related lifecycle records, or expose stored values.
A constrained singleton sweep row can later retain a redacted ordered cursor
across restarts so referenced events cannot starve later cleanup candidates.
The row remains inert until the fixed event-retention store is implemented.

Complete LLM payload retention remains disabled by default. Enabling it does
not permit credentials, private endpoints, or unrelated source data to be
stored, and deployments must treat retained payloads as sensitive.

## Event groups

Event groups separate conversation policy from event severity. A complete
example with common groups and reply probabilities is:

```yaml
event_groups:
  operations:
    reply_probability: 0.25
  recovery:
    reply_probability: 0.40
  social:
    reply_probability: 0.75
  user:
    reply_probability: 1.00
  system:
    reply_probability: 0.05
```

Operators may add groups. Every event-producing trigger and every group-based
route must resolve to a declared group. Event-group IDs must be unique across
all included files, and version 1 accepts at most 256 groups in total. Empty
event-group categories are valid; the validator does not synthesize the groups
shown above.

## Personas

A persona file contains reusable identity, machine-readable selection data,
and a reference to prompt material. It must not contain cluster-specific
service IDs or private operator information.

```yaml
personas:
  - id: observer
    display_name: Observer
    avatar: https://example.com/avatars/observer.png
    prompt_file: ../prompts/observer.md
    enabled: true
    interests:
      monitoring: 1.0
      recovery: 0.6
    behavior:
      spontaneous_weight: 0.3
      reply_weight: 0.8
      cooldown: 30m
    relationships: {}
    metadata: {}
```

Prompt files may describe personality, voice, world view, short examples,
forbidden expressions, desired message length, and attitudes toward other
personas. They do not grant tools or alter factual event decisions.

Persona IDs must be unique across all included files, and version 1 accepts at
most 256 personas. `id`, `display_name`, and `prompt_file` are required;
`enabled` defaults to true and optional maps default to empty. Display names are
limited to 128 UTF-8 bytes, avatar values must be HTTPS URLs no longer than
2,048 bytes, and interests contain at most 256 portable event-group IDs with
non-negative weights. Non-empty `relationships` and `metadata` are reserved
until their semantics are fixed and are rejected by version 1 validation.

## Bindings

Bindings associate events with weighted persona candidates independently from
persona identity:

```yaml
bindings:
  - id: monitoring-characters
    match:
      group: operations
    candidates:
      - persona: observer
        weight: 1.0
      - persona: caretaker
        weight: 0.4
```

Candidate persona references must exist and candidate weights must be
non-negative. A disabled persona may remain referenced but is excluded at
runtime. Binding IDs must be unique across all included files, and version 1
accepts at most 256 bindings with 1 to 256 candidates each. A persona may occur
only once within a binding. Binding and candidate order has no semantic meaning;
group and persona references are resolved after all categories are parsed.
The implemented catalog loader rejects bindings that reference an unknown group
or persona. Disabled personas remain valid references and are excluded later by
runtime selection.

## Triggers

### Event triggers

```yaml
triggers:
  - id: monitoring-failure
    event:
      match:
        all:
          - field: type
            operator: equals
            value: observation.failed
          - field: labels.category
            operator: equals
            value: monitoring
    action:
      type: start_conversation
      binding: monitoring-characters
    cooldown: 30m
```

`match.all` contains 1 to 32 conjunctive predicates. Fields are limited to
`type`, `source`, `subject`, `group`, `severity`, `labels.<id>`, and
`facts.<id>`. The dynamic `<id>` starts with an ASCII letter or digit and then
contains only ASCII letters, digits, `_`, or `-`. `equals` and `not_equals` take
a scalar `value`; `in` takes 1 to 32 distinct scalar `values`; `exists` takes no
operand; and `greater_than` and `less_than` take a numeric `value`. Scalar
strings are limited to 1,024 UTF-8 bytes. Configuration cannot contain
disjunctions, regular expressions, deeper paths, Elixir, Lua, JavaScript,
shell, SQL, PromQL, or arbitrary HTTP expressions.

Matcher evaluation is deterministic application code. All predicates are
conjunctive; a missing dynamic key never matches, `exists` requires a non-null
value, scalar comparisons require a scalar event value, and ordered comparisons
require a numeric event value. Integer and equivalent floating-point values
compare equally.

Implemented event-trigger documents accept at most 256 triggers across all
included files. Trigger IDs must be unique, `action.type` is currently limited
to `start_conversation`, cooldowns use the duration grammar up to 365 days, and
binding references remain unresolved until complete configuration assembly.

The complete configuration loader resolves each event trigger's binding against
the assembled binding namespace and rejects unknown references. It validates
the single default route in the same startup value, but does not read its secret
file or connect to Discord.

### Schedule triggers

```yaml
triggers:
  - id: daily-summary
    schedule:
      cron: "0 21 * * *"
      timezone: Asia/Tokyo
    action:
      type: emit_event
      event:
        type: schedule.fired
        group: social
        subject: daily-summary
```

Schedule cron expressions contain exactly five space-delimited fields: minute,
hour, day of month, month, and day of week. Seconds, year fields, and special
aliases such as `@daily` are not accepted. Named months and weekdays, ranges,
lists, and steps follow standard cron syntax. Timezones must resolve within the
IANA snapshot embedded in the release; validation never consults host zoneinfo
or downloads timezone data at runtime.

At least one of day-of-month or day-of-week must be the unrestricted `*` field.
This avoids the incompatible OR and AND interpretations used by common cron
implementations when both fields are constrained.

The action is limited to `emit_event`. Event type, group, and subject are
portable IDs, and complete configuration assembly resolves the group against
the declared event-group namespace. Schedule and event trigger IDs share one
namespace and count toward the same version 1 limit of 256 triggers. Validation
does not execute schedules or emit events.

### Stochastic triggers

```yaml
triggers:
  - id: occasional-murmur
    stochastic:
      distribution: shifted_exponential
      mean_interval: 8h
      minimum_interval: 2h
      active_hours:
        start: "08:00"
        end: "23:00"
        timezone: Asia/Tokyo
      daily_limit: 3
    action:
      type: emit_event
      event:
        type: stochastic.fired
        group: social
        subject: ambient-conversation
```

Version 1 supports only `shifted_exponential`, sampled as the minimum interval
plus an exponential random delay whose mean is the difference between
`mean_interval` and `minimum_interval`. Both intervals must be positive, the
mean must be greater than the minimum, and neither may exceed 365 days.

`active_hours` and `daily_limit` are optional. Active-hour endpoints use strict
24-hour `HH:MM` notation, must differ, may define a window that crosses
midnight, and use an embedded IANA timezone. A daily limit is an integer from 1
through 10,000 and requires `active_hours` so its daily reset has an explicit
timezone. The action and event-group reference follow the schedule trigger
contract. Validation does not sample randomness, calculate a next run, persist
counters, or emit events.

The separate pure scheduling boundary calculates a next run by sampling one
wait and adding it to a caller-supplied canonical UTC instant. It does not read
a clock, inspect scheduler state, persist the result, or execute an action.

Claimed execution planning rechecks active-hours and daily-limit eligibility at
the supplied execution instant. Ineligible work is skipped without sampling a
new wait; an eligible plan contains only the configured event template and the
redacted values needed for a later completion record.

The shared pure emitted-event projector derives a complete bounded event from
the trigger kind, configured trigger ID, template, and scheduled UTC instant.
The same scheduled version and exact template produce the same immutable event
across retries. Template drift preserves the scheduled event ID so idempotent
persistence rejects changed facts instead of accepting a duplicate. Its fixed
labels contain only the configured trigger ID and kind; prompt fact projection
excludes both labels.

The constrained stochastic commit store reprojects that exact event and writes
it in the same SQLite transaction that advances the opaque claimed schedule to
its planned next run. An identical precommitted event is restored; template
drift or schedule conflict fails closed without advancing the claim. Worker
timing, due enumeration, and later event-trigger dispatch remain explicit
runtime assembly work.

The explicit stochastic cycle performs that due enumeration. It traverses
cursor pages of at most 100 and validates and correlates no more than the
configuration maximum of 256 schedules before the first claim. This prevents
an ineligible first page from hiding eligible later work. It rejects duplicate
or out-of-order durable projections, leaves inactive or daily-limited entries
unclaimed, and continues a prevalidated batch after individual claim or commit
conflicts. Returned claims and typed commit results must correlate exactly with
their calls before execution is counted. Its result contains aggregate counts
only. No stochastic timer is installed in the public application tree, and
committed-event dispatch remains a separate runtime step.

An opt-in stochastic scheduler can invoke that cycle repeatedly without
overlap. It requires an explicit validated configuration, cycle module, UTC
clock, random source, interval, and initial delay; no live defaults are
provided. The next timer is scheduled only after the synchronous cycle returns,
and only an exact bounded, correlated aggregate result is retained. Status
inspection excludes configuration and event details. The worker is not
installed in the public application supervision tree automatically.

The persistence layer also provides a dedicated event-dispatch outbox for the
crash-safe handoff that follows event commit. It accepts only exact immutable
events already in the event store and returns a claim-free enqueue receipt. It
lists at most 100 pending or expired entries without claim data, grants one
opaque fixed 60-second lease, and completes only that exact live claim. A
stochastic commit inserts its immutable event, enqueues this claim-free
handoff, and advances the claimed schedule in one transaction. The outbox does
not perform external I/O. A pure planner can correlate its ordered batch
with restored immutable events and cap current trigger matches before any
claim. Existing fixed starter and bounded-conversation consumers can preflight
the resulting durable plan without authorizing work. An explicit bounded cycle
then claims entries in order, immediately consumes matching fixed pipelines,
and completes only unmatched or fully terminal handoffs. It is not installed
in the public application supervision tree automatically.

An opt-in event-dispatch scheduler can invoke that cycle repeatedly without
overlap. It requires an explicit validated configuration, dispatch context,
fixed persistence and authorizer adapters, cycle module, UTC clock, interval,
and initial delay. The next timer is scheduled only after the synchronous cycle
returns. Status retains only a validated redacted aggregate result or a stable
failure class. The scheduler supplies no live defaults and is not installed in
the public application supervision tree automatically.

Active windows include their start minute and exclude their end minute. A
crossing-midnight window is active from its start through local midnight and
from midnight up to its end. Both instants in a repeated DST wall-clock minute
have the same active-hours status.

Daily limits use the trigger timezone's local calendar date. For a window that
crosses midnight, executions after midnight count toward the new calendar date,
not the date on which the window began. Active-hours exclusion takes precedence
over a reached daily limit in the eligibility reason.
Runtime eligibility requires the loaded execution count to be tagged with this
calculated local date and rejects mismatched buckets.

## LLM provider

The first provider uses an OpenAI-compatible API:

```yaml
llm:
  provider: openai_compatible
  base_url_env: CLUSTER_MURMUR_LLM_BASE_URL
  model_env: CLUSTER_MURMUR_LLM_MODEL
  api_key_file_env: CLUSTER_MURMUR_LLM_API_KEY_FILE
  timeout: 20s
  max_output_tokens: 300
```

`base_url_env` and `model_env` name environment variables containing deployment
values. `api_key_file_env` names an environment variable whose value is the
path to a mounted secret file. The API key itself is never accepted in YAML or
as a direct environment-variable value. The manifest parser requires this exact
mapping, supports only `openai_compatible`, bounds `timeout` to 1 through
120,000 milliseconds after duration parsing, and bounds `max_output_tokens` to
1 through 4,096. The normalized redacted value enters the complete startup
configuration. The runtime settings boundary accepts it directly, resolves the
three deployment values with fixed bounds, and does not make a provider
connection.

## Discord routing

The MVP publishes through one pre-created webhook and therefore supports only
the default route:

```yaml
routing:
  default:
    webhook_secret_file_env: CLUSTER_MURMUR_DISCORD_WEBHOOK_FILE
```

The named environment variable contains the path to a mounted file, not the
webhook URL. Its name is a portable ASCII environment-variable identifier of at
most 128 bytes. Version 1 requires exactly one default routing document.
Group-specific routes are a post-MVP extension. Their future shape
is reserved as `routing.groups`, but version 1 validation must reject that field
until multi-channel routing is implemented and reviewed. The implemented
runtime settings boundary loads this file with fixed bounds and accepts only a
token-bearing HTTPS Discord incoming-webhook URL; it does not execute the
webhook.

Startup loads the provider and webhook boundaries into one redacted runtime
settings aggregate before constructing any external adapter. A failure is
identified only as a stable provider or webhook settings error; deployment
values and secret-file paths are never included in the aggregate's inspection
output or returned errors. This combined step still performs no network call.
The startup preparation boundary runs complete configuration loading before
this settings step and returns them together only after both validate. It does
not start runtime workers or external transports.

## Secret handling

Public configuration may contain only environment-variable names and fake,
portable examples. The following values belong in mounted secret files or the
operator's private deployment repository:

- Discord webhook URLs;
- LLM API keys;
- MCP credentials;
- private endpoints and concrete source inventories;
- private persona prompts; and
- environment-specific channel routing.

Secret readers must impose file-size limits, reject empty values, avoid
following unsafe references, and never include file contents or resolved paths
in logs or validation errors. The shared mounted-secret reader accepts only an
absolute path from a validated named environment variable and a regular-file
target, reads at most 16 KiB, and returns a trimmed non-empty UTF-8 value.
Projected-volume symlinks are allowed when their final target is a regular
file. Secret-specific settings validate the returned opaque value before use.
