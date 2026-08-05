defmodule ClusterMurmur.Persistence.ConversationRecordTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.Conversation
  alias ClusterMurmur.Persistence.ConversationRecord

  test "builds a redacted record from one pristine starting conversation" do
    conversation = conversation()

    assert %{valid?: true} =
             changeset =
             ConversationRecord.start_changeset(%ConversationRecord{}, conversation)

    record = Ecto.Changeset.apply_changes(changeset)

    assert record.id == conversation.id
    assert record.root_event_id == conversation.root_event_id
    assert record.status == :starting
    assert record.turn_count == 0
    assert record.llm_call_count == 0
    assert record.started_at == conversation.started_at
    assert record.completed_at == nil
  end

  test "rejects invalid, advanced, or projected conversations" do
    valid = conversation()

    invalid = [
      nil,
      Map.put(valid, :unexpected_private_value, "private"),
      %{valid | id: "invalid id"},
      %{valid | status: :generating},
      %{valid | last_message_at: valid.started_at},
      %{valid | turn_count: 1},
      %{valid | llm_call_count: 1},
      %{valid | participants: ["observer"]},
      %{valid | messages: [%{"content" => "private"}]}
    ]

    for rejected <- invalid do
      changeset = ConversationRecord.start_changeset(%ConversationRecord{}, rejected)
      refute changeset.valid?
      assert changeset.changes == %{}
      refute inspect(changeset) =~ "private"
    end
  end

  test "rejects loaded, prefilled, and forged persistence records" do
    loaded =
      %ConversationRecord{}
      |> Ecto.put_meta(state: :loaded)

    for record <- [
          loaded,
          %ConversationRecord{status: :failed},
          Ecto.put_meta(%ConversationRecord{}, source: "events"),
          Ecto.put_meta(%ConversationRecord{}, prefix: "private"),
          Map.put(%ConversationRecord{}, :unexpected_private_value, "private")
        ] do
      changeset = ConversationRecord.start_changeset(record, conversation())
      refute changeset.valid?
      assert changeset.changes == %{}
    end
  end

  test "redacts records and valid changesets" do
    private = "private-conversation"
    conversation = %{conversation() | id: private, root_event_id: "private-event"}
    changeset = ConversationRecord.start_changeset(%ConversationRecord{}, conversation)
    record = Ecto.Changeset.apply_changes(changeset)

    for inspected <- [inspect(record), inspect(changeset)] do
      refute inspected =~ private
      refute inspected =~ "private-event"
      refute inspected =~ "2026"
    end
  end

  defp conversation do
    %Conversation{
      id: "conversation-1",
      root_event_id: "event-1",
      status: :starting,
      started_at: ~U[2026-08-05 12:00:00.000000Z],
      last_message_at: nil,
      turn_count: 0,
      llm_call_count: 0,
      participants: [],
      messages: []
    }
  end
end
