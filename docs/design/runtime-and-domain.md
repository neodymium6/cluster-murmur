# Runtime and domain design

This page explains the runtime pipeline, domain model, trigger behavior,
generation, publication, and persistence. It is part of the current
[system design](../../DESIGN.md).

## Runtime pipeline

```text
External Sources
      |
      v
Source Adapters (MCP / timers / future Discord consumer)
      |
      v
Observation Normalization
      |
      v
Event Extraction (state comparison / debounce / dedupe)
      |
      v
Event Store and Event Bus
      |
      v
Trigger Engine (event / schedule / stochastic)
      |
      v
Conversation Director (speaker selection / budgets)
      |
      v
Message Generator (prompt / LLM / validation / fallback)
      |
      v
Discord Publisher
```

## Domain model

### Observation

An observation is a normalized source snapshot with `source`, `subject`,
`state`, `observed_at`, bounded facts, and bounded labels. It never directly
causes a Discord post. Comparison with persisted entity state produces events.

### Event

An event is immutable and contains an ID, type, source, subject, group,
severity, previous/current values, occurrence and observation times, dedupe and
correlation keys, facts, and labels. Before matching, persistence, or prompt
construction, event timestamps are canonical UTC values and event payloads are
validated as bounded JSON-compatible data with explicit depth, collection,
node, string, and aggregate-size limits.

Standard event types are:

- `observation.state_changed`, `observation.failed`, and
  `observation.recovered`;
- `alert.activated` and `alert.resolved`;
- `schedule.fired` and `stochastic.fired`;
- reserved `discord.mentioned`; and
- `system.started`.

### Persona

A persona is immutable configuration, not an OTP process. Machine-readable
fields include interests, selection weights, cooldown, relationships, enabled
state, avatar, and display name. Prompt material contains personality, voice,
world view, examples, forbidden expressions, desired length, and attitudes
toward other personas.

### Binding

A binding matches events and provides weighted persona candidates. It keeps
reusable persona definitions independent from a specific cluster topology.

### Conversation

A conversation tracks its root event, status, start and last-message times,
turn and LLM-call counters, participants, and messages. Valid states are
`starting`, `generating`, `waiting`, `completed`, `cancelled`, and `failed`.

## Event extraction

Default state transitions are deterministic:

| Previous | Current | Result |
| --- | --- | --- |
| unknown | healthy | no event |
| unknown | unhealthy | `observation.failed` |
| healthy | healthy | no event |
| healthy | unhealthy | `observation.failed` |
| unhealthy | unhealthy | no event |
| unhealthy | healthy | `observation.recovered` |

The initial healthy observation is silent. A configurable debounce requires two
consecutive failures and two consecutive successes by default, with source or
subject overrides. Dedupe keys suppress repeated events within configured
windows without suppressing persistence of the current entity state.

## Trigger engine

Event triggers match a bounded declarative vocabulary: equality, inequality,
membership, existence, greater-than, and less-than. Arbitrary Elixir, Lua, or
JavaScript expressions are forbidden.

Schedule triggers emit events from a cron expression and IANA timezone.
Stochastic triggers persist the next run sampled as:

```text
next_wait = minimum_interval + exponential_random_delay
```

They may define active hours and a daily limit. On restart, the scheduler
compares the persisted next-run time with the injected clock and restores the
schedule deterministically.

## Event groups and speaker selection

Event importance is separate from conversation policy. Default conversation
groups are `operations`, `recovery`, `social`, `user`, and `system`; users may
add groups. Each group defines reply probability independently from severity.

The starter is chosen from the matching binding. A sole candidate is selected
directly. Multiple candidates use an injected weighted random generator over
binding weight, event interest, ownership, spontaneous preference, recent
speaker penalty, and cooldown. A candidate on cooldown is normally excluded.
An event with no candidate is persisted but not published.

A reply is first gated by the event group's probability. Candidate responders
exclude disabled personas, the previous speaker, cooldowns, unrelated personas,
zero relevance, and exhausted limits. Selection considers binding, interest,
relationship, reply preference, novelty, and recent speaker penalties.
`no_reply` remains a weighted candidate.

Default conversation budgets are three turns, two participants, five minutes,
and three LLM calls. Application code enforces these budgets regardless of LLM
output.

## Generation

The first provider targets an OpenAI-compatible API through a provider
behaviour. Base URL and model names are referenced by environment-variable
names. API keys are read from files whose paths are supplied through an
environment variable; secret values never appear in YAML.

The prompt separates persona instructions, confirmed facts, creative context,
and bounded recent conversation. The validator rejects empty or oversized
output, suppresses Discord mentions and URLs, removes control characters, and
reduces redundant self-identification. Generated text may use humor, metaphor,
light irony, fictional emotion, and short in-world dialogue. It may not invent
causes, measurements, remediation, recovery, credentials, endpoints, or MCP
activity. Provider failures fall back to a deterministic template generator.

## Discord and memory

The MVP publishes through a pre-created Discord Webhook. Each request supplies
the persona's display name, avatar URL, and content. Discord Gateway ingestion
is deferred; a future Nostrum consumer will normalize mentions into the
reserved `discord.mentioned` event.

Only generated messages and directly relevant future mention messages are
stored. Context is bounded by message counts and token budget. Complete channel
history, long-term vector memory, and persistent persona emotions are excluded
from the MVP.

## Persistence

Ecto with SQLite stores:

- `entity_states` for committed and pending state plus debounce counters;
- `events` for immutable extracted events;
- `trigger_executions` for outcomes and cooldowns;
- `conversations` and `messages` for bounded conversation history;
- `persona_cooldowns` for selection state; and
- `stochastic_schedules` for restart-safe future runs and daily limits.

Entity state is retained indefinitely by default. Events are retained for 90
days; conversations, messages, and trigger executions for 30 days. Complete
LLM payload storage is disabled by default.
