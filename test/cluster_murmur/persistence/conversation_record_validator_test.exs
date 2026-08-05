defmodule ClusterMurmur.Persistence.ConversationRecordValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{ConversationRecord, ConversationRecordValidator}

  test "accepts exact loaded records in every valid lifecycle state" do
    for record <- [
          loaded(:starting, nil),
          loaded(:generating, nil),
          loaded(:waiting, nil),
          loaded(:completed, ~U[2026-08-05 12:01:00.000000Z]),
          loaded(:cancelled, ~U[2026-08-05 12:01:00.000000Z]),
          loaded(:failed, ~U[2026-08-05 12:01:00.000000Z])
        ] do
      assert ConversationRecordValidator.validate(record) == :ok
    end

    assert ConversationRecordValidator.validate_started(loaded(:starting, nil)) == :ok

    for status <- [:starting, :generating, :waiting] do
      assert ConversationRecordValidator.validate_active(loaded(status, nil)) == :ok
    end
  end

  test "started validation requires a pristine start" do
    for record <- [
          %{loaded(:starting, nil) | turn_count: 1},
          %{loaded(:starting, nil) | llm_call_count: 1},
          loaded(:generating, nil),
          loaded(:completed, ~U[2026-08-05 12:01:00.000000Z])
        ] do
      assert ConversationRecordValidator.validate_started(record) ==
               {:error, :invalid_conversation_record}
    end
  end

  test "active validation rejects terminal records" do
    for status <- [:completed, :cancelled, :failed] do
      assert ConversationRecordValidator.validate_active(
               loaded(status, ~U[2026-08-05 12:01:00.000000Z])
             ) == {:error, :invalid_conversation_record}
    end
  end

  test "rejects forged metadata, shapes, values, and loaded precision" do
    valid = loaded(:starting, nil)

    invalid = [
      nil,
      %ConversationRecord{},
      Map.put(valid, :unexpected_private_value, "private"),
      Ecto.put_meta(valid, state: :built),
      Ecto.put_meta(valid, source: "events"),
      Ecto.put_meta(valid, prefix: "private"),
      %{valid | id: "invalid id"},
      %{valid | root_event_id: ""},
      %{valid | status: :unknown},
      %{valid | turn_count: -1},
      %{valid | started_at: %{valid.started_at | microsecond: {0, 0}}},
      %{valid | completed_at: ~U[2026-08-05 12:01:00.000000Z]}
    ]

    for record <- invalid do
      assert ConversationRecordValidator.validate(record) ==
               {:error, :invalid_conversation_record}
    end
  end

  test "requires terminal completion at loaded precision and after start" do
    valid = loaded(:completed, ~U[2026-08-05 12:01:00.000000Z])

    for completed_at <- [
          nil,
          ~U[2026-08-05 11:59:59.999999Z],
          ~U[2026-08-05 12:01:00Z]
        ] do
      assert ConversationRecordValidator.validate(%{valid | completed_at: completed_at}) ==
               {:error, :invalid_conversation_record}
    end
  end

  defp loaded(status, completed_at) do
    %ConversationRecord{
      __meta__: Ecto.put_meta(%ConversationRecord{}, state: :loaded).__meta__,
      id: "conversation-1",
      root_event_id: "event-1",
      status: status,
      turn_count: 0,
      llm_call_count: 0,
      started_at: ~U[2026-08-05 12:00:00.000000Z],
      completed_at: completed_at
    }
  end
end
