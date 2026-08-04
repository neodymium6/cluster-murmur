# Configuration Reference

## Status and scope

This document defines the public configuration contract targeted by the MVP.
The runtime is still at the bootstrap stage, so examples describe intended
behavior rather than currently available functionality.

Configuration controls observations, event policy, personas, bindings,
triggers, generation limits, and outbound routing. It must never contain
credentials, webhook URLs, private endpoints, or environment-specific
identifiers.

## Loading model

Configuration uses YAML 1.2. Duration and common scalar validation are
implemented, but document loading and the remaining validation pipeline are
still design targets. A fixed top-level file includes files by category:

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

Relative paths are resolved from the directory containing the top-level file.
Glob expansion order has no semantic meaning. Configuration is loaded once at
startup; hot reload is outside the MVP.

## Validation

Loading has two fail-closed stages:

1. JSON Schema validates document structure and rejects unknown fields.
2. Elixir semantic validation resolves references and validates values that
   JSON Schema cannot safely establish.

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

Event groups separate conversation policy from event severity. The default
groups and reply probabilities are:

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
route must resolve to a declared group.

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
