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
end
