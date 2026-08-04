defmodule ClusterMurmur.DomainValuesTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.Conversation
  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Observations.Observation
  alias ClusterMurmur.Personas.Persona

  @now ~U[2026-01-01 00:00:00Z]

  test "constructs the public observation value with bounded-data defaults" do
    observation = %Observation{
      source: "example-observer",
      subject: "example-target",
      state: :healthy,
      observed_at: @now
    }

    assert observation.facts == %{}
    assert observation.labels == %{}
  end

  test "constructs the public event value with bounded-data defaults" do
    event = %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-observer",
      occurred_at: @now
    }

    assert event.facts == %{}
    assert event.labels == %{}
  end

  test "constructs personas as immutable configuration values" do
    persona = %Persona{id: "observer", display_name: "Observer"}

    assert persona.interests == %{}
    assert persona.behavior == %{}
    assert persona.relationships == %{}
    assert persona.metadata == %{}
  end

  test "constructs bounded conversation state" do
    conversation = %Conversation{id: "example-conversation", status: :starting}

    assert conversation.participants == []
    assert conversation.messages == []
  end

  test "redacts sensitive runtime domain values from inspection" do
    observation = %Observation{
      source: "hidden-observation-source",
      subject: "hidden-observation-subject",
      state: :unhealthy,
      observed_at: @now,
      facts: %{"fact" => "hidden-observation-fact"},
      labels: %{"label" => "hidden-observation-label"}
    }

    event = %Event{
      id: "hidden-event-id",
      type: "observation.failed",
      source: "hidden-event-source",
      subject: "hidden-event-subject",
      group: "hidden-event-group",
      severity: "warning",
      previous: %{"state" => "hidden-previous-state"},
      current: %{"state" => "hidden-current-state"},
      occurred_at: @now,
      observed_at: ~U[2026-01-01 00:01:00Z],
      dedupe_key: "hidden-dedupe-key",
      correlation_key: "hidden-correlation-key",
      facts: %{"fact" => "hidden-event-fact"},
      labels: %{"label" => "hidden-event-label"}
    }

    conversation = %Conversation{
      id: "hidden-conversation-id",
      root_event_id: "hidden-root-event-id",
      status: :generating,
      started_at: ~U[2026-01-01 00:02:00Z],
      last_message_at: ~U[2026-01-01 00:03:00Z],
      turn_count: 2,
      llm_call_count: 1,
      participants: ["hidden-participant"],
      messages: [%{"content" => "hidden-message"}]
    }

    assert inspect(observation) =~ "state: :unhealthy"
    assert inspect(event) =~ "type: \"observation.failed\""
    assert inspect(conversation) =~ "status: :generating"

    inspected_values = Enum.map([observation, event, conversation], &inspect/1)

    for inspected <- inspected_values do
      refute inspected =~ "private"
      refute inspected =~ "facts"
      refute inspected =~ "labels"
      refute inspected =~ "messages"
    end

    hidden_observation_values = [
      "hidden-observation-source",
      "hidden-observation-subject",
      "hidden-observation-fact",
      "hidden-observation-label"
    ]

    hidden_event_values = [
      "hidden-event-id",
      "hidden-event-source",
      "hidden-event-subject",
      "hidden-event-group",
      "hidden-previous-state",
      "hidden-current-state",
      "2026-01-01 00:01:00",
      "hidden-dedupe-key",
      "hidden-correlation-key",
      "hidden-event-fact",
      "hidden-event-label"
    ]

    hidden_conversation_values = [
      "hidden-conversation-id",
      "hidden-root-event-id",
      "2026-01-01 00:02:00",
      "2026-01-01 00:03:00",
      "hidden-participant",
      "hidden-message"
    ]

    for hidden <- hidden_observation_values ++ hidden_event_values ++ hidden_conversation_values,
        inspected <- inspected_values do
      refute inspected =~ hidden
    end
  end
end
