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
binding, routing, and event-trigger validation, cross-category character catalog
assembly, and complete startup configuration assembly are implemented. A fixed
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

The version 1 manifest contains exactly `version` and `includes`. All five
include categories shown above must be present, even when a category has no
patterns, and unknown fields or categories are invalid. Category values are
lists of strings. The 64-pattern limit applies to the sum across every category,
not separately to each resolver call.

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

IDs are portable ASCII strings suitable for persistence keys. They start with
an ASCII letter or digit and continue with ASCII letters, digits, `.`, `_`, or
`-`. Human-facing fields such as `display_name` may use Unicode. Durations use
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
automatic migration execution, and retention behavior remain later stages.

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

memory:
  current_conversation_messages: 12
  recent_persona_messages: 6
  recent_channel_messages: 8
  maximum_context_tokens: 2000

retention:
  entity_states: forever
  events: 90d
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
to `start_conversation`, cooldowns use the duration grammar, and binding
references remain unresolved until complete configuration assembly.

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
as a direct environment-variable value.

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
until multi-channel routing is implemented and reviewed.

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
in logs or validation errors.
