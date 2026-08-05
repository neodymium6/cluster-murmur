defmodule ClusterMurmur.Generation.FallbackGeneratorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Generation.FallbackGenerator
  alias ClusterMurmur.Messages.{Message, Validator}

  test "builds one validated deterministic neutral template for every event type" do
    for type <- ["observation.failed", "observation.recovered", "schedule.reminder"] do
      event = event(type: type)

      assert {:ok, %Message{} = first} =
               FallbackGenerator.generate(event, "conversation-1", "observer", generated_at())

      assert FallbackGenerator.generate(
               event,
               "conversation-1",
               "observer",
               generated_at()
             ) == {:ok, first}

      assert first.origin == :fallback
      assert first.content == "A confirmed event was recorded."
      assert first.discord_message_id == nil
      assert first.conversation_id == "conversation-1"
      assert first.persona_id == "observer"
      assert first.inserted_at == generated_at()
      assert Validator.validate(first) == :ok
    end
  end

  test "does not infer state semantics from an uncorrelated event type" do
    contradictory =
      event(
        type: "observation.recovered",
        previous: %{"state" => "healthy"},
        current: %{"state" => "unhealthy"}
      )

    assert {:ok, message} =
             FallbackGenerator.generate(
               contradictory,
               "conversation-1",
               "observer",
               generated_at()
             )

    assert message.content == "A confirmed event was recorded."
    refute message.content =~ "healthy"
    refute message.content =~ "recovered"
  end

  test "never interpolates arbitrary event data or provider details" do
    private_values = [
      "private.example.com",
      "https://example.com/private",
      "192.0.2.10",
      "<@12345>",
      "provider-secret"
    ]

    event =
      event(
        type: Enum.at(private_values, 0),
        subject: Enum.at(private_values, 0),
        previous: Enum.at(private_values, 1),
        current: Enum.at(private_values, 2),
        facts: %{"mention" => Enum.at(private_values, 3)},
        labels: %{"error" => Enum.at(private_values, 4)}
      )

    assert {:ok, message} =
             FallbackGenerator.generate(event, "conversation-1", "observer", generated_at())

    assert message.content == "A confirmed event was recorded."
    assert Validator.validate(message) == :ok
    assert Enum.all?(private_values, &(not String.contains?(message.content, &1)))
  end

  test "requires an exact validated event" do
    valid = event([])

    for rejected <- [
          nil,
          %{},
          %{valid | id: ""},
          %{valid | facts: %{"invalid" => :atom}},
          Map.put(valid, :unexpected_private_value, "private")
        ] do
      result =
        FallbackGenerator.generate(
          rejected,
          "conversation-1",
          "observer",
          generated_at()
        )

      assert result == {:error, :invalid_event}
      refute inspect(result) =~ "private"
    end
  end

  test "requires a generation instant at or after event observation" do
    observed = event(observed_at: ~U[2026-08-05 12:00:01.000000Z])

    assert {:ok, _message} =
             FallbackGenerator.generate(
               observed,
               "conversation-1",
               "observer",
               ~U[2026-08-05 12:00:01.000000Z]
             )

    for inserted_at <- [
          nil,
          %{generated_at() | hour: 24},
          ~U[2026-08-05 12:00:00.999999Z]
        ] do
      assert FallbackGenerator.generate(
               observed,
               "conversation-1",
               "observer",
               inserted_at
             ) == {:error, :invalid_datetime}
    end
  end

  test "rejects invalid message identities through the shared output boundary" do
    for {conversation_id, persona_id} <- [
          {nil, "observer"},
          {"invalid id", "observer"},
          {"conversation-1", nil},
          {"conversation-1", "invalid persona"}
        ] do
      assert FallbackGenerator.generate(event([]), conversation_id, persona_id, generated_at()) ==
               {:error, :invalid_message}
    end
  end

  test "redacts the generated message inspection" do
    assert {:ok, message} =
             FallbackGenerator.generate(
               event([]),
               "private-conversation",
               "private-persona",
               generated_at()
             )

    inspected = inspect(message)
    assert inspected =~ "origin: :fallback"
    refute inspected =~ "private"
    refute inspected =~ "unhealthy"
    refute inspected =~ "2026"
  end

  defp generated_at, do: ~U[2026-08-05 12:00:02.000000Z]

  defp event(overrides) do
    struct!(
      Event,
      Keyword.merge(
        [
          id: "event-1",
          type: "observation.failed",
          source: "example-observer",
          subject: "example-target",
          group: "operations",
          severity: "warning",
          previous: %{"state" => "healthy"},
          current: %{"state" => "unhealthy"},
          occurred_at: ~U[2026-08-05 12:00:00.000000Z],
          observed_at: ~U[2026-08-05 12:00:01.000000Z],
          dedupe_key: nil,
          correlation_key: nil,
          facts: %{},
          labels: %{}
        ],
        overrides
      )
    )
  end
end
