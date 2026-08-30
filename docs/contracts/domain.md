# System boundary and domain values

This page defines the system boundary and public domain values. It is part of
the normative [MVP runtime contract](../mvp-contract.md).

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

An authenticated external adapter will use a narrower normalized value before
application-owned identity projection:

```elixir
defmodule ClusterMurmur.Ingestion.EventEnvelope do
  @enforce_keys [
    :idempotency_key,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :occurred_at,
    :facts,
    :labels
  ]

  defstruct @enforce_keys
end
```

The envelope cannot select a trigger, binding, persona, prompt, model,
publisher, endpoint, tool, or credential. Its exact source must be configured,
its type, group, subject, fact keys, and label keys must pass that source's
allowlists, and its group must exist in the event-group catalog. Facts are a
flat map of JSON scalars, labels are a flat string map, severity is `info`,
`warning`, or `critical`, and occurrence time is canonical UTC. Defining this
value does not expose a listener or durable ingestion capability.

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

Event facts and labels accept only JSON-compatible values. A complete event is
bounded to 256 entries per collection, eight collection levels, 1,024 total
nodes, 512-byte keys, 16 KiB strings, and 64 KiB of aggregate key and string
content. Observation entity state reuses that boundary before persistence.
Matchers and prompt projection apply their narrower application-owned field
allowlists before supplied facts reach policy or generation.
