defmodule ClusterMurmur.Conversations.ValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.{Conversation, Validator}
  alias ClusterMurmur.DomainLimits

  test "accepts exact bounded conversations in every lifecycle state" do
    for status <- [:starting, :generating, :waiting, :completed, :cancelled, :failed] do
      assert Validator.validate(valid_conversation(status)) == :ok
    end

    assert Validator.validate(%{
             valid_conversation(:waiting)
             | last_message_at: ~U[2026-08-05 12:01:00Z],
               turn_count: 2,
               llm_call_count: 1,
               participants: ["observer", "operator"]
           }) == :ok
  end

  test "rejects forged shapes, invalid IDs, statuses, and counters" do
    valid = valid_conversation(:starting)
    maximum = DomainLimits.max_safe_integer()

    invalid = [
      nil,
      %Conversation{},
      Map.put(valid, :unexpected_private_value, "private"),
      %{valid | id: "invalid id"},
      %{valid | root_event_id: ""},
      %{valid | status: :unknown},
      %{valid | turn_count: nil},
      %{valid | turn_count: -1},
      %{valid | turn_count: maximum + 1},
      %{valid | llm_call_count: 1.0},
      %{valid | llm_call_count: maximum + 1}
    ]

    for conversation <- invalid do
      assert Validator.validate(conversation) == {:error, :invalid_conversation}
    end
  end

  test "requires canonical ordered UTC instants" do
    valid = valid_conversation(:waiting)

    invalid = [
      %{valid | started_at: nil},
      %{valid | started_at: %{valid.started_at | hour: 24}},
      %{valid | started_at: DateTime.shift_zone!(valid.started_at, "Etc/GMT+1")},
      %{valid | last_message_at: %{valid.started_at | time_zone: "UTC"}},
      %{valid | last_message_at: DateTime.add(valid.started_at, -1, :microsecond)}
    ]

    for conversation <- invalid do
      assert Validator.validate(conversation) == {:error, :invalid_conversation}
    end
  end

  test "bounds a unique portable participant projection" do
    valid = valid_conversation(:waiting)
    participants = Enum.map(1..256, &"persona-#{&1}")

    assert Validator.validate(%{valid | participants: participants}) == :ok

    for invalid_participants <- [
          ["observer", "observer"],
          ["invalid persona"],
          participants ++ ["persona-257"],
          ["observer" | :improper],
          nil
        ] do
      assert Validator.validate(%{valid | participants: invalid_participants}) ==
               {:error, :invalid_conversation}
    end
  end

  test "rejects messages until a typed bounded message projection exists" do
    valid = valid_conversation(:generating)

    assert Validator.validate(%{valid | messages: [%{"content" => "private"}]}) ==
             {:error, :invalid_conversation}
  end

  defp valid_conversation(status) do
    %Conversation{
      id: "conversation-1",
      root_event_id: "event-1",
      status: status,
      started_at: ~U[2026-08-05 12:00:00Z],
      last_message_at: nil,
      turn_count: 0,
      llm_call_count: 0,
      participants: [],
      messages: []
    }
  end
end
