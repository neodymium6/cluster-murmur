defmodule ClusterMurmur.Persistence.MessageRecordTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Persistence.MessageRecord

  test "builds a redacted record changeset from one validated message" do
    message = message([])

    assert %{valid?: true} = changeset = MessageRecord.changeset(%MessageRecord{}, message)
    record = Ecto.Changeset.apply_changes(changeset)

    assert record.id == nil
    assert record.conversation_id == message.conversation_id
    assert record.persona_id == message.persona_id
    assert record.origin == message.origin
    assert record.content == message.content
    assert record.discord_message_id == message.discord_message_id
    assert record.inserted_at == message.inserted_at
  end

  test "rejects invalid and forged messages without retaining values" do
    valid = message([])

    invalid = [
      nil,
      Map.put(valid, :unexpected_private_value, "private"),
      %{valid | conversation_id: "invalid id"},
      %{valid | origin: :system},
      %{valid | content: "hidden\tcontrol"},
      %{valid | discord_message_id: "0"},
      %{valid | inserted_at: %{valid.inserted_at | hour: 24}}
    ]

    for rejected <- invalid do
      changeset = MessageRecord.changeset(%MessageRecord{}, rejected)
      refute changeset.valid?
      assert changeset.changes == %{}
      refute inspect(changeset) =~ "private"
    end
  end

  test "rejects loaded, prefilled, and forged persistence records" do
    for record <- [
          Ecto.put_meta(%MessageRecord{}, state: :loaded),
          %MessageRecord{origin: :fallback},
          Ecto.put_meta(%MessageRecord{}, source: "events"),
          Ecto.put_meta(%MessageRecord{}, prefix: "private"),
          Map.put(%MessageRecord{}, :unexpected_private_value, "private")
        ] do
      changeset = MessageRecord.changeset(record, message([]))
      refute changeset.valid?
      assert changeset.changes == %{}
    end
  end

  test "redacts records and valid changesets" do
    private = "private-message-value"

    message =
      message(
        conversation_id: "private-conversation",
        persona_id: "private-persona",
        content: private
      )

    changeset = MessageRecord.changeset(%MessageRecord{}, message)
    record = Ecto.Changeset.apply_changes(changeset)

    for inspected <- [inspect(record), inspect(changeset)] do
      assert inspected =~ "origin: :llm"
      refute inspected =~ private
      refute inspected =~ "private-conversation"
      refute inspected =~ "private-persona"
      refute inspected =~ "2026"
    end
  end

  defp message(overrides) do
    struct!(
      Message,
      Keyword.merge(
        [
          conversation_id: "conversation-1",
          persona_id: "observer",
          origin: :llm,
          content: "A bounded fact.",
          discord_message_id: "12345",
          inserted_at: ~U[2026-08-05 12:01:00.000000Z]
        ],
        overrides
      )
    )
  end
end
