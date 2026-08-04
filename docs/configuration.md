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
decoding of the included YAML documents are implemented, but the remaining
validation pipeline is still a design target. A value-free Draft 7 validation
adapter for application-owned schemas and bounded event-group validation are
implemented; the remaining category schemas and semantic validators remain
future changes. A fixed top-level file
includes files by category:

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
Prompt files are loaded through a separate bounded text-file interface in a
future change.

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
runtime.

## Triggers

### Event triggers

```yaml
triggers:
  - id: monitoring-failure
    event:
      match:
        type: observation.failed
        labels:
          category: monitoring
    action:
      type: start_conversation
      binding: monitoring-characters
    cooldown: 30m
```

The matcher vocabulary is limited to `equals`, `not_equals`, `in`, `exists`,
`greater_than`, and `less_than`. Configuration cannot contain Elixir, Lua,
JavaScript, shell, SQL, PromQL, or arbitrary HTTP expressions.

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
plus an exponential random delay. The next run and daily counters are durable.

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
webhook URL. Group-specific routes are a post-MVP extension. Their future shape
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
