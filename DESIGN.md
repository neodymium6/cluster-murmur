# Cluster Murmur System Design

## Status

This document is the initial architecture baseline. The repository is at the
early foundation stage: core domain values, external dependency behaviours,
deterministic observation state-transition classification, and common scalar
configuration validation are present. Bounded configuration include resolution
and YAML document decoding are also implemented. The remaining runtime behavior
described here is not implemented yet.

The normative public configuration surface is documented in
[`docs/configuration.md`](docs/configuration.md). Testable MVP invariants,
persistence fields, and acceptance criteria are documented in
[`docs/mvp-contract.md`](docs/mvp-contract.md).

## Overview

Cluster Murmur is an event-driven character conversation orchestrator. It
periodically consumes normalized, read-only observations, extracts meaningful
state changes, selects configured personas, generates short expressions, and
publishes bounded conversations to Discord.

```text
Kubernetes / Prometheus / Alertmanager / Flux / HTTP / TCP / DNS
                              |
                              v
                   cluster-observer-mcp
                    read-only observations
                              | MCP
                              v
                      cluster-murmur
         observation -> event -> trigger -> conversation
                              |
                              v
                           Discord
```

Cluster Murmur does not monitor or diagnose infrastructure itself. A separate
read-only source such as `cluster-observer-mcp` owns that boundary.

## Project identity

| Item | Value |
| --- | --- |
| Repository | `cluster-murmur` |
| Elixir application | `:cluster_murmur` |
| Root module | `ClusterMurmur` |
| CLI | `cluster-murmur` |
| Runtime | Elixir on Erlang/OTP |
| Persistence | Ecto with SQLite |
| Deployment | OCI container on Kubernetes |
| License | Apache-2.0 |

## Responsibilities

The MVP owns:

1. Periodic observation retrieval from `cluster-observer-mcp`.
2. Event extraction from the difference between current and persisted state.
3. Configuration-driven event, schedule, and stochastic triggers.
4. Binding-based persona candidate resolution and weighted speaker selection.
5. Persona-specific message generation through an LLM provider.
6. Discord Webhook publication with per-persona username and avatar overrides.
7. Short probabilistic replies from another relevant persona.
8. Low-frequency spontaneous conversations sampled from a shifted exponential
   distribution.
9. SQLite persistence for state, events, conversations, cooldowns, and future
   stochastic runs.
10. Strict configuration validation that prevents startup on invalid input.

The following are explicit non-goals:

- infrastructure creation, update, deletion, or autonomous remediation;
- generic shell, SSH, `kubectl`, SQL, URL, or PromQL execution;
- unbounded MCP tool access controlled by an LLM;
- automatic assertion of an unobserved root cause;
- unbounded persona conversations or storage of complete Discord history; and
- persistent emotional or relationship changes between personas.

Discord mention responses, question-scoped MCP tools, temporary persona mood,
summarized memory, multiple channels, additional observation sources, multiple
LLM providers, and correlation events are post-MVP extensions.

## Design principles

### Separate facts from expression

Application code determines observations, state transitions, failures,
recoveries, severity, and trigger decisions. The LLM only expresses confirmed
facts in a persona's voice. It never decides whether an incident exists, who
speaks, whether the conversation continues, or which MCP tool may run.

### Separate personas, events, and bindings

A persona defines identity and expression. An event defines what happened. A
binding associates an event with candidate personas. Cluster-specific service
identifiers stay out of reusable persona definitions.

### Abstract external dependencies

MCP clients, LLM providers, Discord publishers, clocks, random generators, and
persistent stores are accessed through Elixir behaviours. Domain code must not
depend directly on a specific provider or transport.

### Guarantee convergence

Every conversation is bounded by maximum turns, participants, duration, LLM
calls, per-persona limits, and cooldowns. Consecutive messages from the same
persona are disabled by default, and `no_reply` is always a valid outcome.

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
correlation keys, facts, and labels.

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

## Configuration

Configuration uses YAML 1.2 with JSON Schema structural validation and Elixir
semantic validation. Unknown fields, duplicate IDs, unresolved persona,
binding, or event-group references, malformed durations, cron expressions, and
timezones are fatal at startup. Configuration loads once; hot reload is not an
MVP feature. Glob order has no semantic meaning. The implemented decoder
requires one mapping-rooted document, accepts only the Core Schema value subset,
and enforces byte, scalar, node-count, and nesting limits before later
configuration-specific validation.

Configuration is split into a top-level include file plus event groups,
routing, personas, bindings, triggers, and prompt files. Secret values never
appear in these files. Routing and provider configuration reference environment
variables that point to mounted secret files.

## OTP architecture

```text
ClusterMurmur.Supervisor
|-- ClusterMurmur.Repo
|-- ClusterMurmur.Config.Registry
|-- ClusterMurmur.Personas.Registry
|-- ClusterMurmur.Events.Bus
|-- ClusterMurmur.Events.StateTracker
|-- ClusterMurmur.Observations.Supervisor
|-- ClusterMurmur.Triggers.Supervisor
|-- ClusterMurmur.Conversations.Registry
|-- ClusterMurmur.Conversations.Supervisor
|-- ClusterMurmur.Generation.RateLimiter
`-- ClusterMurmur.Discord.Publisher
```

The default strategy is `:one_for_one`. Conversations run below a
`DynamicSupervisor`, start on demand, and terminate after reaching a terminal
state. Personas remain configuration data.

## Future question boundary

Mention support will resolve a persona, classify the question, obtain an
application-enforced allowlist from a tool-policy behaviour, execute bounded
MCP calls in Cluster Murmur, normalize facts, and only then ask the LLM to
express an answer. MCP connection details are never delegated to the LLM. Tool
use is disabled by default and will enforce limits on rounds, calls, time, and
parallelism.

## Deployment

The MVP deployment is one Kubernetes Deployment with an OCI container,
ConfigMap volume, Secret volume, and SQLite PVC. The standard connection to
`cluster-observer-mcp` is loopback HTTP in the same Pod; a bounded stdio child
process remains an alternative.

The container runs as non-root with a read-only root filesystem, all
capabilities dropped, graceful shutdown, health endpoints, a fixed public
configuration path, and only SQLite and temporary paths writable. A private
overlay owns credentials, concrete endpoints, routing, PVC details, and network
policy.

## Verification strategy

Unit tests cover matching, bindings, weighted choice, cooldowns, transitions,
dedupe, stochastic sampling, prompt construction, and output validation.
Integration tests cover the complete fake-observer to fake-Discord path and
restart restoration. Replay tests inject identical clocks and random sequences.
Property tests prove non-negative weights, empty-candidate behavior, hard
conversation bounds, cooldown exclusion, and the stochastic minimum interval.

The mature CI target includes formatting, warnings-as-errors compilation,
tests, Credo, Dialyzer, schema and example validation, an OCI build, and a
dependency audit. The bootstrap CI currently runs only checks supported by the
files and dependencies already present.

## Implementation phases

1. Foundation: Mix project, configuration, schema, Ecto/SQLite, behaviours, and
   core domain models.
2. Observations and events: MCP adapter, pollers, state tracker, extractor,
   event store, and dedupe.
3. Triggers: matcher, event groups, cron, shifted exponential schedules, and
   persisted cooldowns.
4. Conversations: weighted persona selection, dynamic processes, budgets, and
   deterministic templates.
5. LLM and Discord: provider, prompts, output validation, fallback, and webhook
   publication.
6. Productionization: OCI image, hardening, metrics, structured logging,
   retention, CI, and release process.
7. Mention extension: Gateway consumer, persona resolution, question
   coordinator, tool policy, and bounded tool-call loop.
