# MVP Runtime Contract

## Status and interpretation

This document records the concrete behavior that an MVP implementation must
satisfy. `DESIGN.md` explains the architecture and ADRs explain material
decisions; this document defines testable runtime invariants and completion
criteria.

The keywords **must**, **must not**, **should**, and **may** are normative. The
repository is currently at the early foundation stage, so this document
describes the completed target unless a capability is explicitly identified as
implemented elsewhere.

## System boundary

Cluster Murmur owns normalized observation ingestion, event extraction,
trigger evaluation, persona selection, bounded conversation orchestration,
LLM-based expression, Discord publication, and short-term generated-message
memory.

It must not expose generic shell, SSH, `kubectl`, SQL, arbitrary PromQL, or
arbitrary HTTP capabilities. Infrastructure credentials, raw infrastructure
APIs, probe execution, and diagnostic access control remain in a read-only
observer such as `cluster-observer-mcp`.

Application code, not the LLM, must determine:

- whether a failure, recovery, or other event occurred;
- the event's severity and group;
- which persona starts or replies;
- whether a conversation continues;
- whether an MCP tool is permitted; and
- whether a result is publishable.

## Core values

The initial Elixir domain values have the following public fields. Additional
private fields may be added without weakening validation or the boundaries in
this document.

```elixir
defmodule ClusterMurmur.Observations.Observation do
  @enforce_keys [:source, :subject, :state, :observed_at]

  defstruct [
    :source,
    :subject,
    :state,
    :observed_at,
    facts: %{},
    labels: %{}
  ]
end
```

```elixir
defmodule ClusterMurmur.Events.Event do
  @enforce_keys [:id, :type, :source, :occurred_at]

  defstruct [
    :id,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :previous,
    :current,
    :occurred_at,
    :observed_at,
    :dedupe_key,
    :correlation_key,
    facts: %{},
    labels: %{}
  ]
end
```

```elixir
defmodule ClusterMurmur.Personas.Persona do
  @enforce_keys [:id, :display_name]

  defstruct [
    :id,
    :display_name,
    :avatar,
    :prompt,
    :enabled,
    interests: %{},
    behavior: %{},
    relationships: %{},
    metadata: %{}
  ]
end
```

```elixir
defmodule ClusterMurmur.Conversations.Conversation do
  defstruct [
    :id,
    :root_event_id,
    :status,
    :started_at,
    :last_message_at,
    :turn_count,
    :llm_call_count,
    participants: [],
    messages: []
  ]
end
```

Conversation status is one of `starting`, `generating`, `waiting`, `completed`,
`cancelled`, or `failed`. Persona values are immutable configuration and must
not become independent OTP processes.

Facts and labels must pass explicit field allowlists, nesting limits, and
serialized-size limits before persistence or prompt construction. Limits will
be fixed alongside the observation schema before Phase 2 is complete.

## External dependency contracts

Domain and orchestration code use injected behaviours rather than concrete
clients:

```elixir
defmodule ClusterMurmur.Clock do
  @callback now() :: DateTime.t()
  @callback monotonic_time_ms() :: integer()
end

defmodule ClusterMurmur.Random do
  @callback uniform() :: float()
  @callback weighted_choice([{term(), number()}]) ::
              {:ok, term()} | :empty
end

defmodule ClusterMurmur.Observers.Client do
  @callback list_targets() ::
              {:ok, [%{required(:id) => String.t()}]}
              | {:error, ClusterMurmur.ExternalError.t()}
  @callback observe_target(String.t()) ::
              {:ok, ClusterMurmur.Observations.Observation.t()}
              | {:error, ClusterMurmur.ExternalError.t()}
end

defmodule ClusterMurmur.Generation.Provider do
  @callback generate(
              ClusterMurmur.Generation.PromptRequest.t(),
              ClusterMurmur.Generation.ProviderSettings.t(),
              (ClusterMurmur.Generation.OpenAICompatibleRequest.t() -> term())
            ) ::
              {:ok, String.t()} | {:error, ClusterMurmur.ExternalError.t()}
end

defmodule ClusterMurmur.Discord.Publisher do
  @callback publish(
              ClusterMurmur.Persistence.PublicationAttemptRecord.t(),
              ClusterMurmur.Discord.PublicationPlanner.Plan.t(),
              ClusterMurmur.Persistence.MessageRecord.t(),
              ClusterMurmur.Personas.Persona.t(),
              ClusterMurmur.Discord.WebhookSettings.t(),
              (ClusterMurmur.Discord.WebhookRequest.t() -> term())
            ) ::
              {:ok, String.t(), ClusterMurmur.Persistence.PublicationAttemptRecord.t()}
              | {:failed, ClusterMurmur.ExternalError.t(),
                 ClusterMurmur.Persistence.PublicationAttemptRecord.t()}
              | {:ambiguous, :interrupted,
                 ClusterMurmur.Persistence.PublicationAttemptRecord.t()}
              | {:error, atom()}
end
```

Tests must be able to replace every behaviour with a deterministic fake.
Persistence must similarly remain behind repository or store boundaries so
selection and conversation policy do not depend directly on Ecto queries.

The OpenAI-compatible provider adapter revalidates one fixed request before one
injected transport call. It performs no retry and returns only decoded content
or stable external error classes; raw provider responses and diagnostics remain
inside the adapter boundary.

Discord publication claims one exact durable `started` attempt immediately
before invoking the injected transport. Only the compare-and-set winner may
dispatch. HTTP responses that prove rejection are known failures; malformed
successes, timeouts after dispatch, 5xx responses, and unknown transport
outcomes are ambiguous and must not be retried.

The observer adapter exposes only named, bounded, read-only operations. A
concrete adapter maps those operations to MCP tools internally, validates
arguments, and normalizes responses without exposing tool names, arbitrary
argument maps, or raw responses to application code.
Application code then rejects target lists above 256 entries or 64 KiB of ID
text, duplicate or malformed identities, and nondeterministic response order
before making any per-target observation call.
One bounded poll lists targets once, observes every accepted target once in
stable order, requires normalized observation identity to match that target,
and delegates each accepted value to atomic ingestion. Per-target failures are
classified without stopping the remaining bounded batch or exposing target
data; catalog and startup-input failures stop before observation calls.
One matched event trigger can then be planned and durably authorized without
executing its action. Only an exact redacted started capability whose event,
trigger, execution instant, and cooldown projection still match the plan may
cross into later action orchestration.
For one event, matching triggers are selected from a bounded catalog and
authorized once in stable trigger-ID order. Per-trigger cooldown, repeated-pair,
and stable failure outcomes do not stop the remaining bounded batch, while only
validated durable authorizations for triggers still exactly present in the
supplied configuration cross into later action orchestration.

`Clock.monotonic_time_ms/0` uses milliseconds. `Random.uniform/0` returns a
finite value in `[0.0, 1.0)`, and `Random.weighted_choice/1` returns `:empty`
when its input is empty or all weights are zero. Callers must reject non-finite
or negative weights before invoking the random adapter.

## Observation and event rules

An observation never publishes directly. State tracking first applies the
configured debounce and then compares the committed previous state:

| Previous | Current | Event |
| --- | --- | --- |
| unknown | healthy | none |
| unknown | unhealthy | `observation.failed` |
| healthy | healthy | none |
| healthy | unhealthy | `observation.failed` |
| unhealthy | unhealthy | none |
| unhealthy | healthy | `observation.recovered` |

The initial healthy observation is silent. The current entity state must still
be persisted when event publication is suppressed.

Every extracted event has a stable dedupe key, for example:

```text
observation.failed:example-target
observation.recovered:example-target
alert.activated:example-target:example-alert
```

Repeated keys within a configured dedupe window do not execute triggers again.
Suppression, including its reason, must be observable without logging complete
facts or source responses.

## Trigger and selection rules

Triggers are limited to event, schedule, and stochastic types. Correlation is
reserved for later work. Matchers use only the operators defined in the
configuration reference and never execute embedded code.

Starter candidates come from the matched binding. A candidate on cooldown is
normally excluded. With one eligible candidate, that persona is selected.
With multiple candidates, the selector computes a non-negative weight from:

```text
binding weight
+ event interest
+ ownership bonus
+ persona spontaneous weight
- recent speaker penalty
- cooldown penalty
```

The injected random behaviour performs only the final weighted sample. If no
candidate exists, the event remains persisted and no Discord message is sent.

A reply is first gated by the event group's reply probability. Responder
candidates exclude:

- disabled personas;
- the previous speaker when consecutive speech is disabled;
- personas on cooldown;
- personas absent from the binding;
- personas with zero relevance; and
- personas that have reached a conversation limit.

Eligible responder weights combine binding weight, event interest,
relationship with the previous speaker, reply weight, novelty, and recent
speaker penalties. The candidate set must always include weighted `no_reply`.
Weights are clamped or rejected before sampling so a negative weight never
reaches the random adapter.

## Conversation convergence

All conversations must enforce the configured limits for turns, participants,
duration, LLM calls, persona continuity, cooldowns, and re-entry. The default
limits are specified in `configuration.md`.

The director checks the relevant budget before every generation, publication,
and continuation. An LLM response cannot extend a conversation. A terminal
conversation process must stop normally under the conversation
`DynamicSupervisor`.

At-least-once delivery or a process restart must not create an unbounded
conversation. A pure publication planner now skips records whose Discord ID is
already committed. Before production readiness, execution and recovery must
still define a policy for the ambiguous crash window between Discord acceptance
and recording the returned Discord message ID; that outcome must not be blindly
retried.

## Generation contract

Prompt construction separates identity, facts, creative context, and bounded
conversation history. The logical input has this shape:

```json
{
  "persona": {
    "display_name": "Example Observer",
    "instructions": "Speak briefly and do not invent causes."
  },
  "facts": {
    "subject": "example-backup",
    "previous_state": "failed",
    "current_state": "healthy"
  },
  "creative_context": {
    "conversation_kind": "recovery",
    "mood": "relieved"
  },
  "conversation": [
    {
      "speaker": "Example Caretaker",
      "content": "The latest run completed."
    }
  ]
}
```

The LLM may add humor, metaphor, light irony, fictional emotion, or short
in-world dialogue. It must not invent a cause, measurement, repair, recovery,
credential, endpoint, or MCP action.

Before publication, deterministic validation must:

- reject empty output;
- enforce a configured character limit;
- suppress Discord user, role, and broadcast mentions;
- suppress URLs;
- remove control characters; and
- reduce redundant use of the speaker's own display name.

Provider failure, timeout, malformed response, or rejected output falls back
to a deterministic template generated only from confirmed facts. Fallbacks
consume conversation budgets and must pass the same output validator.

## Discord publication

The MVP is outbound-only. Each publication supplies content plus the selected
persona's display name and avatar override to a pre-created Discord Webhook.
Webhook URLs are read from mounted secret files and must never be returned in
errors or logs. Publication payloads always send an empty `allowed_mentions`
parse list so Discord cannot expand user, role, or broadcast mentions.

Discord Gateway ingestion and `discord.mentioned` event production are not MVP
features. The event type and `Questions.ToolPolicy` boundary remain reserved so
future question handling cannot grant tool choice directly to an LLM.

## Persistence contract

Ecto with SQLite stores the following minimum fields. Migrations may add
surrogate keys, timestamps, constraints, and indexes without changing the
domain contract.

### `entity_states`

```text
source
subject
current_state
pending_state
consecutive_count
last_observed_at
last_changed_at
facts
labels
```

### `events`

```text
id
type
source
subject
group
severity
previous
current
dedupe_key
correlation_key
facts
labels
occurred_at
observed_at
inserted_at
```

### `trigger_executions`

```text
trigger_id
event_id
status
executed_at
cooldown_until
error_class
```

### `conversations`

```text
id
root_event_id
status
turn_count
llm_call_count
started_at
completed_at
```

### `messages`

```text
conversation_id
persona_id
origin
content
discord_message_id
inserted_at
```

### `persona_cooldowns`

```text
persona_id
cooldown_until
last_spoken_at
```

### `stochastic_schedules`

```text
trigger_id
next_run_at
last_run_at
daily_count
daily_count_date
claim_token
claim_started_at
claim_expires_at
```

Entity state changes, event insertion, and related trigger bookkeeping should
use transactions where a partial result would change a later decision.
Restart must restore committed entity state, trigger cooldowns, persona
cooldowns, incomplete conversation disposition, and stochastic next-run times.

## Logging and sensitive data

Production logs are structured JSON. They may record:

- observation success or classified failure;
- event creation or suppression;
- trigger match or skip decisions;
- selected persona IDs;
- conversation start and terminal status;
- classified LLM success or failure; and
- classified Discord publication success or failure.

Logs must not contain:

- API keys, bearer tokens, or webhook URLs;
- private endpoints or secret-file contents;
- complete LLM prompts;
- complete MCP responses; or
- unrelated user message content.

Observation data and generated prompts are potentially sensitive. Logging uses
field allowlists, redaction, response-size limits, and stable error classes
rather than raw exception payloads from external providers.

Generic inspection of observation, event, and conversation domain values is
allowlisted and excludes facts, labels, state snapshots, participants, and
messages. Structured logging must still choose only fields justified by the
specific lifecycle event.

## Verification requirements

Unit tests cover event matching, binding resolution, weighted choice,
cooldowns, state transitions, dedupe, shifted exponential sampling, prompt
construction, and output validation.

Integration tests cover the path from a fake observer through event extraction,
triggering, fake generation, fake Discord publication, and SQLite persistence.
They also cover restoration after restart.

Replay tests feed the same event sequence, clock values, and random sequence to
produce the same decisions. Property tests establish at least these invariants:

- computed weights are never negative;
- an empty eligible set never selects a persona;
- conversations never exceed a configured budget;
- a persona on cooldown is not selected; and
- a stochastic run is never scheduled below its minimum interval.

## MVP acceptance criteria

The MVP is complete only when all of the following are demonstrated by
automated checks or a safe local integration test:

1. The application starts with valid configuration.
2. The application refuses to start with invalid configuration.
3. It retrieves normalized observations from `cluster-observer-mcp`.
4. It persists state changes as events.
5. Event triggers can be defined in configuration.
6. Shifted-exponential stochastic triggers can be defined in configuration.
7. It resolves personas related to an event through a binding.
8. It performs injected weighted selection when multiple candidates exist.
9. It generates persona-specific messages through an LLM provider.
10. It falls back to a deterministic template after an LLM failure.
11. It publishes with a persona-specific display name and avatar through a
    Discord Webhook adapter.
12. A different relevant persona can reply according to configured policy.
13. Every conversation terminates within all configured budgets.
14. State, cooldowns, and stochastic next-run times survive restart.
15. The OCI container runs as non-root with the documented filesystem and
    capability restrictions.
16. Formatting, tests, Credo, Dialyzer, configuration validation, and other
    mature CI checks documented in `DESIGN.md` pass.

Acceptance testing must use fake adapters or an explicitly approved isolated
environment. It must not publish to Discord or connect to live infrastructure
without approval for the exact environment and revision.
